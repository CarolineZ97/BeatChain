// scripts/deploy.js
// BeatChain 完整部署脚本
// 按照依赖顺序部署所有合约：
// 1. PlatformTreasury
// 2. EscrowVault (需要 USDC 地址)
// 3. PriceFeed
// 4. ListingManager (需要 EscrowVault 地址)
// 5. RoyaltyDistributor (需要 PlatformTreasury 地址)
// 6. OracleConsumer (需要 RoyaltyDistributor + PriceFeed 地址)
// 7. DelistingManager (需要 PriceFeed + EscrowVault + ListingManager 地址)
// 8. LiquidityBootstrap (需要 USDC 地址)
// 9. 配置合约间权限

const { ethers } = require("hardhat");
const fs = require("fs");
const path = require("path");

// Polygon Mumbai 测试网 USDC 地址
const MUMBAI_USDC = "0x0FA8781a83E46826621b3BC094Ea2A0212e71B23";
const POLYGON_USDC = "0x2791Bca1f2de4661ED88A30C99A7a9449Aa84174";

async function main() {
  const [deployer] = await ethers.getSigners();
  const network = await ethers.provider.getNetwork();
  const chainId = Number(network.chainId);

  console.log("═══════════════════════════════════════════════════════");
  console.log("  BeatChain 合约部署 (含 AMM 做市商模块)");
  console.log("═══════════════════════════════════════════════════════");
  console.log(`  网络:        ${network.name} (chainId: ${chainId})`);
  console.log(`  部署账户:    ${deployer.address}`);
  const balance = await ethers.provider.getBalance(deployer.address);
  console.log(`  账户余额:    ${ethers.formatEther(balance)} MATIC`);
  console.log("═══════════════════════════════════════════════════════\n");

  let usdcAddress;

  // 本地网络：部署 MockUSDC
  if (chainId === 31337) {
    console.log("📦 [本地网络] 部署 MockUSDC...");
    const MockERC20 = await ethers.getContractFactory("MockERC20");
    const mockUSDC = await MockERC20.deploy("USD Coin", "USDC", 6);
    await mockUSDC.waitForDeployment();
    usdcAddress = await mockUSDC.getAddress();
    console.log(`   ✅ MockUSDC 部署成功: ${usdcAddress}`);

    // 铸造测试 USDC 给部署者
    const mintAmount = ethers.parseUnits("10000000", 6); // 10M USDC
    await mockUSDC.mint(deployer.address, mintAmount);
    console.log(`   ✅ 铸造 10,000,000 USDC 给部署者\n`);
  } else if (chainId === 80001) {
    usdcAddress = MUMBAI_USDC;
    console.log(`📌 使用 Mumbai USDC: ${usdcAddress}\n`);
  } else if (chainId === 137) {
    usdcAddress = POLYGON_USDC;
    console.log(`📌 使用 Polygon USDC: ${usdcAddress}\n`);
  } else {
    throw new Error(`不支持的网络 chainId: ${chainId}`);
  }

  const deployedContracts = {};

  // ─── Step 1: PlatformTreasury ──────────────────────────────────────────────
  console.log("📦 [1/9] 部署 PlatformTreasury...");
  const PlatformTreasury = await ethers.getContractFactory("PlatformTreasury");
  const platformTreasury = await PlatformTreasury.deploy(deployer.address);
  await platformTreasury.waitForDeployment();
  deployedContracts.PlatformTreasury = await platformTreasury.getAddress();
  console.log(`   ✅ PlatformTreasury: ${deployedContracts.PlatformTreasury}\n`);

  // ─── Step 2: EscrowVault ───────────────────────────────────────────────────
  console.log("📦 [2/9] 部署 EscrowVault...");
  const EscrowVault = await ethers.getContractFactory("EscrowVault");
  const escrowVault = await EscrowVault.deploy(usdcAddress);
  await escrowVault.waitForDeployment();
  deployedContracts.EscrowVault = await escrowVault.getAddress();
  console.log(`   ✅ EscrowVault: ${deployedContracts.EscrowVault}\n`);

  // ─── Step 3: PriceFeed ─────────────────────────────────────────────────────
  console.log("📦 [3/9] 部署 PriceFeed...");
  const PriceFeed = await ethers.getContractFactory("PriceFeed");
  const priceFeed = await PriceFeed.deploy();
  await priceFeed.waitForDeployment();
  deployedContracts.PriceFeed = await priceFeed.getAddress();
  console.log(`   ✅ PriceFeed: ${deployedContracts.PriceFeed}\n`);

  // ─── Step 4: ListingManager ────────────────────────────────────────────────
  console.log("📦 [4/9] 部署 ListingManager...");
  const ListingManager = await ethers.getContractFactory("ListingManager");
  const listingManager = await ListingManager.deploy(
    usdcAddress,
    deployedContracts.EscrowVault,
    deployedContracts.PlatformTreasury
  );
  await listingManager.waitForDeployment();
  deployedContracts.ListingManager = await listingManager.getAddress();
  console.log(`   ✅ ListingManager: ${deployedContracts.ListingManager}\n`);

  // ─── Step 5: RoyaltyDistributor ────────────────────────────────────────────
  console.log("📦 [5/9] 部署 RoyaltyDistributor...");
  const RoyaltyDistributor = await ethers.getContractFactory("RoyaltyDistributor");
  const royaltyDistributor = await RoyaltyDistributor.deploy(
    usdcAddress,
    deployedContracts.PlatformTreasury
  );
  await royaltyDistributor.waitForDeployment();
  deployedContracts.RoyaltyDistributor = await royaltyDistributor.getAddress();
  console.log(`   ✅ RoyaltyDistributor: ${deployedContracts.RoyaltyDistributor}\n`);

  // ─── Step 6: OracleConsumer ────────────────────────────────────────────────
  console.log("📦 [6/9] 部署 OracleConsumer...");
  const OracleConsumer = await ethers.getContractFactory("OracleConsumer");
  const oracleConsumer = await OracleConsumer.deploy(
    deployedContracts.RoyaltyDistributor,
    deployedContracts.PriceFeed,
    usdcAddress
  );
  await oracleConsumer.waitForDeployment();
  deployedContracts.OracleConsumer = await oracleConsumer.getAddress();
  console.log(`   ✅ OracleConsumer: ${deployedContracts.OracleConsumer}\n`);

  // ─── Step 7: DelistingManager ──────────────────────────────────────────────
  console.log("📦 [7/9] 部署 DelistingManager...");
  const DelistingManager = await ethers.getContractFactory("DelistingManager");
  const delistingManager = await DelistingManager.deploy(
    deployedContracts.PriceFeed,
    deployedContracts.EscrowVault,
    deployedContracts.ListingManager
  );
  await delistingManager.waitForDeployment();
  deployedContracts.DelistingManager = await delistingManager.getAddress();
  console.log(`   ✅ DelistingManager: ${deployedContracts.DelistingManager}\n`);

  // ─── Step 8: LiquidityBootstrap ────────────────────────────────────────────
  console.log("📦 [8/9] 部署 LiquidityBootstrap...");
  const LiquidityBootstrap = await ethers.getContractFactory("LiquidityBootstrap");
  const liquidityBootstrap = await LiquidityBootstrap.deploy(usdcAddress);
  await liquidityBootstrap.waitForDeployment();
  deployedContracts.LiquidityBootstrap = await liquidityBootstrap.getAddress();
  console.log(`   ✅ LiquidityBootstrap: ${deployedContracts.LiquidityBootstrap}\n`);

  // ─── Step 9: 配置合约间权限 ────────────────────────────────────────────────
  console.log("⚙️  [9/9] 配置合约间权限...");

  // EscrowVault: 授权 ListingManager 和 DelistingManager
  await escrowVault.setAuthorizedCaller(deployedContracts.ListingManager, true);
  console.log("   ✅ EscrowVault ← ListingManager (authorized)");

  await escrowVault.setAuthorizedCaller(deployedContracts.DelistingManager, true);
  console.log("   ✅ EscrowVault ← DelistingManager (authorized)");

  // PriceFeed: 授权 OracleConsumer
  await priceFeed.setAuthorizedUpdater(deployedContracts.OracleConsumer, true);
  console.log("   ✅ PriceFeed ← OracleConsumer (authorized)");

  // RoyaltyDistributor: 授权 OracleConsumer
  await royaltyDistributor.setAuthorizedCaller(deployedContracts.OracleConsumer, true);
  console.log("   ✅ RoyaltyDistributor ← OracleConsumer (authorized)");

  // OracleConsumer: 设置 DelistingManager
  await oracleConsumer.setDelistingManager(deployedContracts.DelistingManager);
  console.log("   ✅ OracleConsumer → DelistingManager (set)");

  // ListingManager: 授权 DelistingManager
  await listingManager.setAuthorizedCaller(deployedContracts.DelistingManager, true);
  console.log("   ✅ ListingManager ← DelistingManager (authorized)");

  // ListingManager: 设置 LiquidityBootstrap
  await listingManager.setLiquidityBootstrap(deployedContracts.LiquidityBootstrap);
  console.log("   ✅ ListingManager → LiquidityBootstrap (set)");

  // DelistingManager: 授权 OracleConsumer
  await delistingManager.setAuthorizedCaller(deployedContracts.OracleConsumer, true);
  console.log("   ✅ DelistingManager ← OracleConsumer (authorized)\n");

  // ─── 保存部署地址 ──────────────────────────────────────────────────────────
  const deploymentData = {
    network: network.name,
    chainId: chainId,
    deployer: deployer.address,
    timestamp: new Date().toISOString(),
    usdc: usdcAddress,
    contracts: deployedContracts,
  };

  const outputPath = path.join(__dirname, `../deployments/${chainId}.json`);
  const outputDir = path.dirname(outputPath);
  if (!fs.existsSync(outputDir)) {
    fs.mkdirSync(outputDir, { recursive: true });
  }
  fs.writeFileSync(outputPath, JSON.stringify(deploymentData, null, 2));

  console.log("═══════════════════════════════════════════════════════");
  console.log("  🎉 部署完成！");
  console.log("═══════════════════════════════════════════════════════");
  console.log(`  USDC:                ${usdcAddress}`);
  Object.entries(deployedContracts).forEach(([name, addr]) => {
    console.log(`  ${name.padEnd(22)} ${addr}`);
  });
  console.log(`\n  部署信息已保存至: deployments/${chainId}.json`);
  console.log("═══════════════════════════════════════════════════════");

  return deployedContracts;
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error("❌ 部署失败:", error);
    process.exit(1);
  });
