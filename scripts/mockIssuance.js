// scripts/mockIssuance.js
// 模拟完整的歌曲上架和代币购买流程
// 演示：艺术家提交上架 → 管理员审批 → 投资者购买代币 → 查询持仓

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
  const [deployer, artist, investor1, investor2, investor3] = await ethers.getSigners();
  const network = await ethers.provider.getNetwork();
  const chainId = Number(network.chainId);

  console.log("═══════════════════════════════════════════════════════");
  console.log("  BeatChain 歌曲上架与代币购买模拟");
  console.log("═══════════════════════════════════════════════════════");
  console.log(`  网络:     ${network.name} (chainId: ${chainId})`);
  console.log(`  管理员:   ${deployer.address}`);
  console.log(`  艺术家:   ${artist.address}`);
  console.log(`  投资者1:  ${investor1.address}`);
  console.log(`  投资者2:  ${investor2.address}`);
  console.log(`  投资者3:  ${investor3.address}`);

  const deployment = await loadDeployment(chainId);
  const { contracts, usdc: usdcAddress } = deployment;

  // 获取合约实例
  const listingManager = await ethers.getContractAt("ListingManager", contracts.ListingManager);
  const escrowVault = await ethers.getContractAt("EscrowVault", contracts.EscrowVault);
  const royaltyDistributor = await ethers.getContractAt("RoyaltyDistributor", contracts.RoyaltyDistributor);
  const delistingManager = await ethers.getContractAt("DelistingManager", contracts.DelistingManager);
  const mockUSDC = await ethers.getContractAt("MockERC20", usdcAddress);

  console.log("\n📋 合约地址:");
  console.log(`   ListingManager:      ${contracts.ListingManager}`);
  console.log(`   EscrowVault:         ${contracts.EscrowVault}`);
  console.log(`   RoyaltyDistributor:  ${contracts.RoyaltyDistributor}`);

  // ─── 准备测试 USDC ─────────────────────────────────────────────────────────
  if (chainId === 31337) {
    console.log("\n💰 分发测试 USDC...");
    const artistUsdc = ethers.parseUnits("100000", 6);   // 100,000 USDC 给艺术家（用于押金）
    const investorUsdc = ethers.parseUnits("50000", 6);  // 50,000 USDC 给每个投资者

    await mockUSDC.mint(artist.address, artistUsdc);
    await mockUSDC.mint(investor1.address, investorUsdc);
    await mockUSDC.mint(investor2.address, investorUsdc);
    await mockUSDC.mint(investor3.address, investorUsdc);

    console.log(`   ✅ 艺术家获得 ${ethers.formatUnits(artistUsdc, 6)} USDC`);
    console.log(`   ✅ 每位投资者获得 ${ethers.formatUnits(investorUsdc, 6)} USDC`);
  }

  // ─── 场景 1: 艺术家提交歌曲上架申请 ───────────────────────────────────────
  console.log("\n═══════════════════════════════════════════════════════");
  console.log("  场景 1: 艺术家提交歌曲上架申请");
  console.log("═══════════════════════════════════════════════════════");

  // 歌曲参数
  const songName = "Midnight Dreams";
  const songSymbol = "MDREAM";
  const songURI = "ipfs://QmXxx.../midnight-dreams-metadata.json";
  const totalSupply = ethers.parseUnits("1000000", 18);    // 1,000,000 代币
  const royaltyShareSoldBps = 3000;                         // 出售 30% 版税权
  const issuanceFairValue = ethers.parseUnits("0.1", 6);   // 每代币 0.1 USDC
  const expectedAnnualRoyalty = ethers.parseUnits("120000", 6); // 预期年版税 120,000 USDC
  // 押金 = 40% × 120,000 = 48,000 USDC
  const depositAmount = ethers.parseUnits("48000", 6);

  console.log("\n📝 歌曲信息:");
  console.log(`   歌曲名称:         ${songName}`);
  console.log(`   代币符号:         ${songSymbol}`);
  console.log(`   总供应量:         ${ethers.formatUnits(totalSupply, 18)} 代币`);
  console.log(`   出售版税比例:     ${royaltyShareSoldBps / 100}%`);
  console.log(`   发行公允价值:     ${ethers.formatUnits(issuanceFairValue, 6)} USDC/代币`);
  console.log(`   预期年版税:       ${ethers.formatUnits(expectedAnnualRoyalty, 6)} USDC`);
  console.log(`   安全押金:         ${ethers.formatUnits(depositAmount, 6)} USDC`);

  // 艺术家提交上架申请
  console.log("\n🎵 艺术家提交上架申请...");
  const submitTx = await listingManager.connect(artist).submitListing(
    songName,
    songSymbol,
    songURI,
    totalSupply,
    royaltyShareSoldBps,
    issuanceFairValue,
    expectedAnnualRoyalty,
    depositAmount
  );
  const submitReceipt = await submitTx.wait();

  // 解析 SongSubmitted 事件获取 songId
  let songId;
  for (const log of submitReceipt.logs) {
    try {
      const parsed = listingManager.interface.parseLog(log);
      if (parsed && parsed.name === "SongSubmitted") {
        songId = parsed.args.songId;
        break;
      }
    } catch {}
  }

  console.log(`   ✅ 上架申请提交成功！歌曲 ID: ${songId}`);

  // 查询上架状态
  const listing = await listingManager.getListing(songId);
  console.log(`   状态: ${["PENDING", "ACTIVE", "DELISTED"][listing.status]}`);

  // ─── 场景 2: 管理员审批上架 ────────────────────────────────────────────────
  console.log("\n═══════════════════════════════════════════════════════");
  console.log("  场景 2: 管理员审批上架（部署 MusicToken + 锁定押金）");
  console.log("═══════════════════════════════════════════════════════");

  // 艺术家授权 EscrowVault 扣取押金
  console.log("\n🔐 艺术家授权 EscrowVault 扣取押金...");
  await mockUSDC.connect(artist).approve(contracts.EscrowVault, depositAmount);
  console.log(`   ✅ 已授权 ${ethers.formatUnits(depositAmount, 6)} USDC`);

  // 管理员审批
  console.log("\n✅ 管理员审批上架...");
  const approveTx = await listingManager.connect(deployer).approveListing(songId, songSymbol);
  const approveReceipt = await approveTx.wait();

  let musicTokenAddress;
  for (const log of approveReceipt.logs) {
    try {
      const parsed = listingManager.interface.parseLog(log);
      if (parsed && parsed.name === "SongApproved") {
        musicTokenAddress = parsed.args.musicToken;
        break;
      }
    } catch {}
  }

  console.log(`   ✅ 审批成功！MusicToken 地址: ${musicTokenAddress}`);

  // 验证押金已锁定
  const deposit = await escrowVault.getDeposit(songId);
  console.log(`   ✅ 押金已锁定: ${ethers.formatUnits(deposit.amount, 6)} USDC`);

  // 在 RoyaltyDistributor 注册歌曲
  await royaltyDistributor.connect(deployer).registerSong(songId, musicTokenAddress);
  console.log(`   ✅ 歌曲已在 RoyaltyDistributor 注册`);

  // 在 DelistingManager 注册歌曲
  await delistingManager.connect(deployer).setAuthorizedCaller(deployer.address, true);
  await delistingManager.connect(deployer).registerSong(songId, issuanceFairValue);
  console.log(`   ✅ 歌曲已在 DelistingManager 注册`);

  // ─── 场景 3: 投资者购买代币 ────────────────────────────────────────────────
  console.log("\n═══════════════════════════════════════════════════════");
  console.log("  场景 3: 投资者购买代币");
  console.log("═══════════════════════════════════════════════════════");

  const musicToken = await ethers.getContractAt("MusicToken", musicTokenAddress);

  // 投资者购买金额
  const purchases = [
    { investor: investor1, name: "投资者1", usdcAmount: ethers.parseUnits("10000", 6) },
    { investor: investor2, name: "投资者2", usdcAmount: ethers.parseUnits("5000", 6) },
    { investor: investor3, name: "投资者3", usdcAmount: ethers.parseUnits("3000", 6) },
  ];

  console.log("\n💸 投资者购买代币:");
  for (const { investor, name, usdcAmount } of purchases) {
    // 授权 MusicToken 扣取 USDC
    await mockUSDC.connect(investor).approve(musicTokenAddress, usdcAmount);

    // 购买代币
    const buyTx = await musicToken.connect(investor).purchaseTokens(usdcAmount);
    await buyTx.wait();

    const tokenBalance = await musicToken.balanceOf(investor.address);
    console.log(`   ✅ ${name}: 花费 ${ethers.formatUnits(usdcAmount, 6)} USDC，获得 ${ethers.formatUnits(tokenBalance, 18)} 代币`);
  }

  // ─── 查询最终状态 ──────────────────────────────────────────────────────────
  console.log("\n═══════════════════════════════════════════════════════");
  console.log("  最终状态汇总");
  console.log("═══════════════════════════════════════════════════════");

  const totalRaised = await musicToken.totalUsdcRaised();
  const totalSupplyAfter = await musicToken.totalSupply();
  const saleActive = await musicToken.saleActive();

  console.log(`\n📊 MusicToken 状态:`);
  console.log(`   总融资金额:   ${ethers.formatUnits(totalRaised, 6)} USDC`);
  console.log(`   流通供应量:   ${ethers.formatUnits(totalSupplyAfter, 18)} 代币`);
  console.log(`   代币销售状态: ${saleActive ? "进行中" : "已结束"}`);

  console.log(`\n👥 持仓分布:`);
  for (const { investor, name } of purchases) {
    const balance = await musicToken.balanceOf(investor.address);
    const percentage = (Number(balance) * 100) / Number(totalSupplyAfter);
    console.log(`   ${name}: ${ethers.formatUnits(balance, 18)} 代币 (${percentage.toFixed(2)}%)`);
  }

  const platformTreasury = await ethers.getContractAt("PlatformTreasury", contracts.PlatformTreasury);
  const treasuryBalance = await mockUSDC.balanceOf(contracts.PlatformTreasury);
  console.log(`\n🏦 平台国库余额: ${ethers.formatUnits(treasuryBalance, 6)} USDC`);

  // 保存 MusicToken 地址供后续脚本使用
  deployment.musicTokens = deployment.musicTokens || {};
  deployment.musicTokens[songId.toString()] = musicTokenAddress;
  const outputPath = path.join(__dirname, `../deployments/${chainId}.json`);
  fs.writeFileSync(outputPath, JSON.stringify(deployment, null, 2));

  console.log(`\n✅ 模拟完成！MusicToken 地址已保存至 deployments/${chainId}.json`);
  console.log("═══════════════════════════════════════════════════════");
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error("❌ 模拟失败:", error);
    process.exit(1);
  });
