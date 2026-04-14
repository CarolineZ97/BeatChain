# BeatChain

> **去中心化音乐版税投资平台** — 部署于 Polygon 区块链

BeatChain 是一个基于 Polygon 的去中心化音乐版税投资平台。艺术家将其流媒体版税权利代币化为 ERC-20 代币并出售给投资者；投资者按持仓比例每月获得 USDC 版税分配。多节点 Oracle 网络将经过验证的链下版税数据上链，SPV 信托处理法币到 USDC 的转换，Uniswap v3 流动性池支持二级市场交易。

---

## 项目架构

```
BeatChain/
├── contracts/
│   ├── interfaces/
│   │   ├── IMusicToken.sol          # MusicToken 接口
│   │   ├── IOracle.sol              # Oracle 接口（含 ZK-ML 结构）
│   │   └── IRoyaltyDistributor.sol  # 版税分配接口
│   ├── MusicToken.sol               # 每首歌的 ERC-20 代币合约
│   ├── RoyaltyDistributor.sol       # 版税分配（Pull 模式）
│   ├── OracleConsumer.sol           # 多节点 Oracle + 中位数共识
│   ├── ListingManager.sol           # 歌曲上架生命周期管理
│   ├── EscrowVault.sol              # 艺术家安全押金托管
│   ├── DelistingManager.sol         # 退市监控与执行
│   ├── PriceFeed.sol                # DCF 公允价值存储
│   ├── PlatformTreasury.sol         # 平台费用国库
│   └── MockERC20.sol                # 测试用 USDC 模拟合约
├── scripts/
│   ├── deploy.js                    # 按依赖顺序部署所有合约
│   ├── mockOracle.js                # 模拟 Oracle 提交月度数据
│   └── mockIssuance.js              # 模拟完整歌曲上架与代币购买
├── test/
│   └── beatchain.test.js            # 完整测试套件（7 个核心场景）
├── hardhat.config.js
├── .env.example
└── README.md
```

---

## 合约职责

| 合约 | 职责 |
|------|------|
| `MusicToken.sol` | 每首歌的 ERC-20 代币。存储：总供应量、艺术家钱包、已出售版税份额、发行公允价值。每首歌部署一个实例。 |
| `RoyaltyDistributor.sol` | 接收来自 SPV 信托的 USDC。扣除 1% 平台费。记录每个持有者的可领取余额。使用 Pull 模式（持有者主动领取）。 |
| `OracleConsumer.sol` | 接受白名单 Oracle 节点的版税数据提交。计算所有提交的中位数。拒绝偏差 >20% 的提交（Slash 质押）。数据通过验证后触发 RoyaltyDistributor。 |
| `ListingManager.sol` | 管理歌曲上架生命周期：PENDING、ACTIVE、DELISTED。存储资格标准。在上架时调用 EscrowVault 锁定艺术家押金。 |
| `EscrowVault.sol` | 在上架时以 USDC 锁定艺术家安全押金。若艺术家违约（连续 2 个月未转账），自动将押金分配给代币持有者。干净退市时将押金返还给艺术家。 |
| `DelistingManager.sol` | 每月监控 PriceFeed 的公允价值。若公允价值连续 6 个月低于发行价的 30%，触发退市审查。处理自愿和强制退市流程。 |
| `PriceFeed.sol` | 存储每个代币的 DCF 公允价值，由 Oracle 每月更新。可被 DelistingManager 和前端读取。 |
| `PlatformTreasury.sol` | 接收平台费用（3% 发行费 + 1% 分配费）。仅平台管理员钱包可提取。 |

---

## 关键业务参数

| 参数 | 值 |
|------|-----|
| 平台发行费 | 融资金额的 3% |
| 平台分配费 | 月版税的 1% |
| 艺术家最低保留 | 50% 版税权（最多出售 50%） |
| 艺术家安全押金 | 预期年版税收入的 30%-50% |
| Oracle 偏差阈值 | 20%（超过此值的提交被拒绝） |
| Oracle 最少节点数 | 3 个节点达成共识 |
| 月度更新保障 | 公允价值变化 >25% 触发人工审查标志 |
| 退市触发条件 | 公允价值连续 6 个月低于发行价的 30% |
| 艺术家违约触发 | 连续 2 个月未转账版税 |
| 结算货币 | USDC（ERC-20，Polygon 上的地址） |
| 区块链 | Polygon（开发使用 Mumbai 测试网） |
| 代币标准 | ERC-20 |

---

## 合约交互关系

```
ListingManager
    → calls EscrowVault.lockDeposit()        at listing
    → deploys new MusicToken                 per song

OracleConsumer
    → calls PriceFeed.updateFairValue()      after data passes validation
    → calls RoyaltyDistributor.receiveRoyalty() to trigger distribution
    → calls DelistingManager.recordMonth()   with validated income data

RoyaltyDistributor
    → reads MusicToken.balanceOf()           to compute each holder's share
    → calls PlatformTreasury.depositFee()    for the 1% fee

DelistingManager
    → reads PriceFeed.getFairValue()         monthly
    → calls EscrowVault.distributeToHolders() on confirmed default
    → calls ListingManager.setStatus(DELISTED) on confirmed delisting
```

---

## 部署顺序

合约存在依赖关系，必须按以下顺序部署：

1. `PlatformTreasury`
2. `EscrowVault` (需要 USDC 地址)
3. `PriceFeed`
4. `ListingManager` (需要 EscrowVault 地址)
5. `RoyaltyDistributor` (需要 PlatformTreasury 地址)
6. `OracleConsumer` (需要 RoyaltyDistributor + PriceFeed 地址)
7. `DelistingManager` (需要 PriceFeed + EscrowVault + ListingManager 地址)

---

## 快速开始

### 1. 安装依赖

```bash
cd BeatChain
npm install
```

### 2. 配置环境变量

```bash
cp .env.example .env
# 编辑 .env 填入你的私钥和 RPC URL
```

### 3. 启动本地节点

```bash
npm run node
```

### 4. 部署合约（本地）

```bash
npm run deploy:local
```

### 5. 运行模拟脚本

```bash
# 模拟歌曲上架和代币购买
npm run mock:issuance

# 模拟 Oracle 提交月度数据
npm run mock:oracle
```

### 6. 运行测试

```bash
npm test
```

### 7. 部署到 Mumbai 测试网

```bash
npm run deploy:mumbai
```

---

## 测试覆盖场景

| # | 场景 | 描述 |
|---|------|------|
| 1 | 部署歌曲代币 | 验证总供应量、艺术家份额、版税比例限制 |
| 2 | 购买代币 | 验证持仓余额、3% 发行费、97% 转艺术家 |
| 3 | Oracle 提交数据 | 验证中位数计算（奇数/偶数提交）、最少节点要求 |
| 4 | Oracle 异常值拒绝 | 验证 >20% 偏差被拒绝、节点被 Slash |
| 5 | 版税分配 | 验证 1% 平台费、按比例分配、Pull 领取 |
| 6 | 艺术家违约 | 验证连续 2 个月未付触发违约、押金分配给持有者 |
| 7 | 强制退市 | 验证公允价值连续 6 个月低于 30% 触发退市 |

---

## ZK-ML Oracle 架构说明

本项目实现了文档中描述的 ZK-ML（零知识机器学习）Oracle 架构：

1. **链下计算（Prover）**：Oracle 节点在链下运行 ML 模型（Ridge Regression / DNN），得出预期版税金额，并使用 zk-SNARKs 生成密码学证明。

2. **链上验证（Verifier）**：`OracleConsumer.sol` 接受版税数据 + ZK 证明，通过中位数共识机制验证数据真实性。

3. **异常熔断**：若实际结算金额偏离预期 >20%，Oracle 拒绝该提交并 Slash 节点质押；若偏离 >30%，触发熔断机制，暂停当月分配并进入 72 小时人工审计期。

4. **去中心化验证**：合约只需验证 ZK Proof 的合法性，即可确认链下 ML 算法未被篡改，实现"去中心化验证中心化算法"。

---

## CeDeFi 资金流向

```
投资者 USDC
    ↓ 购买代币
MusicToken.sol
    ├── 3% → PlatformTreasury.sol
    └── 97% → 艺术家钱包

DistroKid 版税（法币）
    ↓ 自动兑换
SPV 信托账户（Circle/Stripe）
    ↓ 转换为 USDC
OracleConsumer.sol（验证）
    ↓ 触发分配
RoyaltyDistributor.sol
    ├── 1% → PlatformTreasury.sol
    └── 99% → 投资者可领取余额（Pull 模式）
```

---

## 许可证

MIT License
