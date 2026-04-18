// scripts/mockOracle.js
// 模拟 Oracle 节点提交每月版税数据
// 演示多节点共识、中位数计算、异常值拒绝机制

const { ethers } = require("hardhat");
const fs = require("fs");
const path = require("path");

async function loadDeployment(chainId) {
  const filePath = path.join(__dirname, `../deployments/${chainId}.json`);
  if (!fs.existsSync(filePath)) {
    throw new Error(`找不到部署文件: ${filePath}，请先运行 deploy.js`);
  }
  return JSON.parse(fs.readFileSync(filePath, "utf8"));
}

async function main() {
  const [deployer, node1, node2, node3, node4] = await ethers.getSigners();
  const network = await ethers.provider.getNetwork();
  const chainId = Number(network.chainId);

  console.log("═══════════════════════════════════════════════════════");
  console.log("  BeatChain Oracle 模拟");
  console.log("═══════════════════════════════════════════════════════");

  const deployment = await loadDeployment(chainId);
  const { contracts, usdc: usdcAddress } = deployment;

  // 获取合约实例
  const oracleConsumer = await ethers.getContractAt("OracleConsumer", contracts.OracleConsumer);
  const royaltyDistributor = await ethers.getContractAt("RoyaltyDistributor", contracts.RoyaltyDistributor);
  const priceFeed = await ethers.getContractAt("PriceFeed", contracts.PriceFeed);
  const mockUSDC = await ethers.getContractAt("MockERC20", usdcAddress);

  console.log("\n📋 合约地址:");
  console.log(`   OracleConsumer:      ${contracts.OracleConsumer}`);
  console.log(`   RoyaltyDistributor:  ${contracts.RoyaltyDistributor}`);
  console.log(`   PriceFeed:           ${contracts.PriceFeed}`);

  // ─── 注册 Oracle 节点 ──────────────────────────────────────────────────────
  console.log("\n🔧 注册 Oracle 节点...");
  const nodes = [node1, node2, node3, node4];
  const nodeNames = ["Node-1", "Node-2", "Node-3", "Node-4 (异常值节点)"];

  for (let i = 0; i < nodes.length; i++) {
    const isRegistered = await oracleConsumer.isOracleNode(nodes[i].address);
    if (!isRegistered) {
      await oracleConsumer.registerNodeAdmin(nodes[i].address);
      console.log(`   ✅ ${nodeNames[i]} 注册成功: ${nodes[i].address}`);
    } else {
      console.log(`   ℹ️  ${nodeNames[i]} 已注册: ${nodes[i].address}`);
    }
  }

  // ─── 模拟场景 1: 正常月度数据提交 ─────────────────────────────────────────
  console.log("\n═══════════════════════════════════════════════════════");
  console.log("  场景 1: 正常月度版税数据提交（3节点共识）");
  console.log("═══════════════════════════════════════════════════════");

  const songId = 1; // 假设 songId=1 已通过 mockIssuance.js 创建

  // 检查 RoyaltyDistributor 是否已注册该歌曲
  const isRegistered = await royaltyDistributor.songRegistered(songId);
  if (!isRegistered) {
    console.log(`\n⚠️  歌曲 #${songId} 未在 RoyaltyDistributor 注册`);
    console.log("   请先运行 mockIssuance.js 创建歌曲列表");
    console.log("   继续演示 Oracle 数据提交流程（不触发分配）...\n");
  }

  // 月度版税金额（USDC，6位小数）
  // 正常数据：三个节点提交接近的数值
  const normalRoyalties = [
    ethers.parseUnits("10000", 6),  // Node-1: 10,000 USDC
    ethers.parseUnits("10200", 6),  // Node-2: 10,200 USDC (偏差 2%)
    ethers.parseUnits("9800", 6),   // Node-3: 9,800 USDC (偏差 2%)
  ];

  console.log("\n📊 各节点提交数据:");
  for (let i = 0; i < 3; i++) {
    console.log(`   ${nodeNames[i]}: ${ethers.formatUnits(normalRoyalties[i], 6)} USDC`);
  }

  // 向 OracleConsumer 存入 USDC（模拟 SPV 信托转账）
  const totalRoyalty = ethers.parseUnits("10000", 6);
  if (chainId === 31337) {
    await mockUSDC.mint(deployer.address, totalRoyalty * 2n);
    await mockUSDC.approve(contracts.OracleConsumer, totalRoyalty * 2n);
    await oracleConsumer.depositRoyaltyFunds(totalRoyalty);
    console.log(`\n   💰 已向 OracleConsumer 存入 ${ethers.formatUnits(totalRoyalty, 6)} USDC（模拟 SPV 信托）`);
  }

  // 模拟 ZK 证明（实际生产中由链下 ZK-ML 系统生成）
  const mockZkProof = ethers.toUtf8Bytes("mock_zk_snark_proof_v1_verified");

  console.log("\n🔄 节点提交数据...");
  for (let i = 0; i < 3; i++) {
    try {
      const tx = await oracleConsumer.connect(nodes[i]).submitRoyaltyData(
        songId,
        normalRoyalties[i],
        mockZkProof
      );
      const receipt = await tx.wait();
      console.log(`   ✅ ${nodeNames[i]} 提交成功 (tx: ${receipt.hash.slice(0, 10)}...)`);
    } catch (err) {
      console.log(`   ⚠️  ${nodeNames[i]} 提交失败: ${err.message.slice(0, 80)}`);
    }
  }

  // 查询轮次结果
  const roundId = await oracleConsumer.getCurrentRoundId(songId);
  if (roundId > 0) {
    const roundData = await oracleConsumer.getRoundData(roundId);
    console.log(`\n📈 轮次 #${roundId} 结果:`);
    console.log(`   中位数版税:  ${ethers.formatUnits(roundData.medianRoyalty, 6)} USDC`);
    console.log(`   提交数量:    ${roundData.submissionCount}`);
    console.log(`   已完成:      ${roundData.finalized}`);
  }

  // ─── 模拟场景 2: 异常值节点提交（应被拒绝）─────────────────────────────────
  console.log("\n═══════════════════════════════════════════════════════");
  console.log("  场景 2: 异常值节点提交（>20% 偏差，应被拒绝并 Slash）");
  console.log("═══════════════════════════════════════════════════════");

  // 开始新一轮（需要等待或使用不同 songId）
  const songId2 = 2;

  const outlierRoyalties = [
    ethers.parseUnits("10000", 6),  // Node-1: 10,000 USDC (正常)
    ethers.parseUnits("10100", 6),  // Node-2: 10,100 USDC (正常，偏差 1%)
    ethers.parseUnits("9900", 6),   // Node-3: 9,900 USDC (正常，偏差 1%)
    ethers.parseUnits("15000", 6),  // Node-4: 15,000 USDC (异常！偏差 50%)
  ];

  console.log("\n📊 各节点提交数据:");
  for (let i = 0; i < 4; i++) {
    const deviation = i === 3 ? " ⚠️  [异常值 +50%]" : "";
    console.log(`   ${nodeNames[i]}: ${ethers.formatUnits(outlierRoyalties[i], 6)} USDC${deviation}`);
  }

  if (chainId === 31337) {
    await mockUSDC.mint(deployer.address, totalRoyalty * 2n);
    await mockUSDC.approve(contracts.OracleConsumer, totalRoyalty * 2n);
    await oracleConsumer.depositRoyaltyFunds(totalRoyalty);
  }

  console.log("\n🔄 节点提交数据（包含异常值）...");
  for (let i = 0; i < 4; i++) {
    try {
      const tx = await oracleConsumer.connect(nodes[i]).submitRoyaltyData(
        songId2,
        outlierRoyalties[i],
        mockZkProof
      );
      const receipt = await tx.wait();

      // 检查事件
      const events = receipt.logs;
      let accepted = true;
      for (const log of events) {
        try {
          const parsed = oracleConsumer.interface.parseLog(log);
          if (parsed && parsed.name === "RoyaltyDataSubmitted") {
            accepted = parsed.args.accepted;
          }
        } catch {}
      }

      const status = i === 3 ? (accepted ? "✅ 接受（意外）" : "❌ 拒绝（预期）") : "✅ 接受";
      console.log(`   ${nodeNames[i]}: ${status}`);
    } catch (err) {
      console.log(`   ⚠️  ${nodeNames[i]} 提交失败: ${err.message.slice(0, 80)}`);
    }
  }

  const roundId2 = await oracleConsumer.getCurrentRoundId(songId2);
  if (roundId2 > 0) {
    const roundData2 = await oracleConsumer.getRoundData(roundId2);
    console.log(`\n📈 轮次 #${roundId2} 结果:`);
    console.log(`   中位数版税:  ${ethers.formatUnits(roundData2.medianRoyalty, 6)} USDC`);
    console.log(`   已完成:      ${roundData2.finalized}`);
  }

  // ─── 查询 PriceFeed ────────────────────────────────────────────────────────
  console.log("\n═══════════════════════════════════════════════════════");
  console.log("  PriceFeed 状态");
  console.log("═══════════════════════════════════════════════════════");

  for (const id of [songId, songId2]) {
    const fairValue = await priceFeed.getFairValue(id);
    if (fairValue > 0) {
      console.log(`   歌曲 #${id} 公允价值: ${ethers.formatUnits(fairValue, 6)} USDC/token`);
    }
  }

  console.log("\n✅ Oracle 模拟完成！");
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error("❌ 模拟失败:", error);
    process.exit(1);
  });
