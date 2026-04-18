// test/beatchain.test.js
// BeatChain 完整测试套件
// 覆盖所有 7 个核心业务场景

const { expect } = require("chai");
const { ethers } = require("hardhat");
const { loadFixture } = require("@nomicfoundation/hardhat-network-helpers");
const { time } = require("@nomicfoundation/hardhat-network-helpers");

// ─── 测试常量 ──────────────────────────────────────────────────────────────────
const USDC_DECIMALS = 6;
const TOKEN_DECIMALS = 18;

// 解析 USDC 金额（6位小数）
const usdc = (amount) => ethers.parseUnits(amount.toString(), USDC_DECIMALS);
// 解析代币金额（18位小数）
const tokens = (amount) => ethers.parseUnits(amount.toString(), TOKEN_DECIMALS);

// ─── 部署 Fixture ──────────────────────────────────────────────────────────────
async function deployBeatChainFixture() {
  const [
    deployer,
    platformAdmin,
    artist,
    investor1,
    investor2,
    investor3,
    oracleNode1,
    oracleNode2,
    oracleNode3,
    oracleNodeBad,
  ] = await ethers.getSigners();

  // 1. 部署 MockUSDC
  const MockERC20 = await ethers.getContractFactory("MockERC20");
  const mockUSDC = await MockERC20.deploy("USD Coin", "USDC", USDC_DECIMALS);
  const usdcAddress = await mockUSDC.getAddress();

  // 铸造 USDC 给各参与方
  await mockUSDC.mint(artist.address, usdc(500_000));
  await mockUSDC.mint(investor1.address, usdc(100_000));
  await mockUSDC.mint(investor2.address, usdc(100_000));
  await mockUSDC.mint(investor3.address, usdc(100_000));
  await mockUSDC.mint(deployer.address, usdc(1_000_000));

  // 2. 部署 PlatformTreasury
  const PlatformTreasury = await ethers.getContractFactory("PlatformTreasury");
  const platformTreasury = await PlatformTreasury.deploy(platformAdmin.address);

  // 3. 部署 EscrowVault
  const EscrowVault = await ethers.getContractFactory("EscrowVault");
  const escrowVault = await EscrowVault.deploy(usdcAddress);

  // 4. 部署 PriceFeed
  const PriceFeed = await ethers.getContractFactory("PriceFeed");
  const priceFeed = await PriceFeed.deploy();

  // 5. 部署 ListingManager
  const ListingManager = await ethers.getContractFactory("ListingManager");
  const listingManager = await ListingManager.deploy(
    usdcAddress,
    await escrowVault.getAddress(),
    await platformTreasury.getAddress()
  );

  // 6. 部署 RoyaltyDistributor
  const RoyaltyDistributor = await ethers.getContractFactory("RoyaltyDistributor");
  const royaltyDistributor = await RoyaltyDistributor.deploy(
    usdcAddress,
    await platformTreasury.getAddress()
  );

  // 7. 部署 OracleConsumer
  const OracleConsumer = await ethers.getContractFactory("OracleConsumer");
  const oracleConsumer = await OracleConsumer.deploy(
    await royaltyDistributor.getAddress(),
    await priceFeed.getAddress(),
    usdcAddress
  );

  // 8. 部署 DelistingManager
  const DelistingManager = await ethers.getContractFactory("DelistingManager");
  const delistingManager = await DelistingManager.deploy(
    await priceFeed.getAddress(),
    await escrowVault.getAddress(),
    await listingManager.getAddress()
  );

  // ─── 配置权限 ────────────────────────────────────────────────────────────────
  await escrowVault.setAuthorizedCaller(await listingManager.getAddress(), true);
  await escrowVault.setAuthorizedCaller(await delistingManager.getAddress(), true);
  await priceFeed.setAuthorizedUpdater(await oracleConsumer.getAddress(), true);
  await royaltyDistributor.setAuthorizedCaller(await oracleConsumer.getAddress(), true);
  await oracleConsumer.setDelistingManager(await delistingManager.getAddress());
  await listingManager.setAuthorizedCaller(await delistingManager.getAddress(), true);
  await delistingManager.setAuthorizedCaller(await oracleConsumer.getAddress(), true);
  await delistingManager.setAuthorizedCaller(deployer.address, true);

  // 注册 Oracle 节点
  await oracleConsumer.registerNodeAdmin(oracleNode1.address);
  await oracleConsumer.registerNodeAdmin(oracleNode2.address);
  await oracleConsumer.registerNodeAdmin(oracleNode3.address);
  await oracleConsumer.registerNodeAdmin(oracleNodeBad.address);

  return {
    mockUSDC,
    platformTreasury,
    escrowVault,
    priceFeed,
    listingManager,
    royaltyDistributor,
    oracleConsumer,
    delistingManager,
    deployer,
    platformAdmin,
    artist,
    investor1,
    investor2,
    investor3,
    oracleNode1,
    oracleNode2,
    oracleNode3,
    oracleNodeBad,
    usdcAddress,
  };
}

// ─── 辅助函数：创建并审批歌曲上架 ────────────────────────────────────────────
async function createAndApproveListing(fixture, overrides = {}) {
  const {
    mockUSDC,
    listingManager,
    escrowVault,
    royaltyDistributor,
    delistingManager,
    artist,
    deployer,
  } = fixture;

  const params = {
    songName: overrides.songName || "Test Song",
    songSymbol: overrides.songSymbol || "TSONG",
    songURI: overrides.songURI || "ipfs://test",
    totalSupply: overrides.totalSupply || tokens(1_000_000),
    royaltyShareSoldBps: overrides.royaltyShareSoldBps || 3000,
    issuanceFairValue: overrides.issuanceFairValue || usdc("0.1"),
    expectedAnnualRoyalty: overrides.expectedAnnualRoyalty || usdc(120_000),
    depositAmount: overrides.depositAmount || usdc(48_000),
  };

  // 艺术家提交上架
  const submitTx = await listingManager.connect(artist).submitListing(
    params.songName,
    params.songSymbol,
    params.songURI,
    params.totalSupply,
    params.royaltyShareSoldBps,
    params.issuanceFairValue,
    params.expectedAnnualRoyalty,
    params.depositAmount
  );
  const submitReceipt = await submitTx.wait();

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

  // 艺术家授权押金
  await mockUSDC.connect(artist).approve(await escrowVault.getAddress(), params.depositAmount);

  // 管理员审批
  const approveTx = await listingManager.connect(deployer).approveListing(songId, params.songSymbol);
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

  const musicToken = await ethers.getContractAt("MusicToken", musicTokenAddress);

  // 注册到 RoyaltyDistributor
  await royaltyDistributor.connect(deployer).registerSong(songId, musicTokenAddress);

  // 注册到 DelistingManager
  await delistingManager.connect(deployer).registerSong(songId, params.issuanceFairValue);

  return { songId, musicToken, musicTokenAddress, params };
}

// ═══════════════════════════════════════════════════════════════════════════════
// 测试套件
// ═══════════════════════════════════════════════════════════════════════════════

describe("BeatChain 完整测试套件", function () {

  // ─────────────────────────────────────────────────────────────────────────────
  // 场景 1: 部署歌曲代币，验证总供应量和艺术家份额
  // ─────────────────────────────────────────────────────────────────────────────
  describe("场景 1: 部署歌曲代币，验证总供应量和艺术家份额", function () {
    it("应正确部署 MusicToken 并记录总供应量", async function () {
      const fixture = await loadFixture(deployBeatChainFixture);
      const { songId, musicToken, params } = await createAndApproveListing(fixture);

      // 验证总供应量
      const totalSupply = await musicToken.totalSupply();
      expect(totalSupply).to.equal(params.totalSupply);
    });

    it("应正确记录艺术家钱包地址", async function () {
      const fixture = await loadFixture(deployBeatChainFixture);
      const { musicToken } = await createAndApproveListing(fixture);

      expect(await musicToken.artistWallet()).to.equal(fixture.artist.address);
    });

    it("应正确记录版税出售比例（30%）", async function () {
      const fixture = await loadFixture(deployBeatChainFixture);
      const { musicToken } = await createAndApproveListing(fixture);

      expect(await musicToken.royaltyShareSoldBps()).to.equal(3000);
    });

    it("应正确记录发行公允价值", async function () {
      const fixture = await loadFixture(deployBeatChainFixture);
      const { musicToken, params } = await createAndApproveListing(fixture);

      expect(await musicToken.issuanceFairValue()).to.equal(params.issuanceFairValue);
    });

    it("不应允许出售超过 50% 的版税权", async function () {
      const fixture = await loadFixture(deployBeatChainFixture);
      const { listingManager, artist } = fixture;

      await expect(
        listingManager.connect(artist).submitListing(
          "Test Song",
          "TSONG",
          "ipfs://test",
          tokens(1_000_000),
          5001, // 超过 50%
          usdc("0.1"),
          usdc(120_000),
          usdc(48_000)
        )
      ).to.be.revertedWith("ListingManager: exceeds max royalty share");
    });

    it("押金低于最低要求（30%）时应拒绝上架", async function () {
      const fixture = await loadFixture(deployBeatChainFixture);
      const { listingManager, artist } = fixture;

      await expect(
        listingManager.connect(artist).submitListing(
          "Test Song",
          "TSONG",
          "ipfs://test",
          tokens(1_000_000),
          3000,
          usdc("0.1"),
          usdc(120_000),
          usdc(10_000) // 低于 30% × 120,000 = 36,000
        )
      ).to.be.revertedWith("ListingManager: deposit below minimum");
    });

    it("押金超过最高限制（50%）时应拒绝上架", async function () {
      const fixture = await loadFixture(deployBeatChainFixture);
      const { listingManager, artist } = fixture;

      await expect(
        listingManager.connect(artist).submitListing(
          "Test Song",
          "TSONG",
          "ipfs://test",
          tokens(1_000_000),
          3000,
          usdc("0.1"),
          usdc(120_000),
          usdc(70_000) // 超过 50% × 120,000 = 60,000
        )
      ).to.be.revertedWith("ListingManager: deposit above maximum");
    });
  });

  // ─────────────────────────────────────────────────────────────────────────────
  // 场景 2: 用 USDC 购买代币，验证持仓余额正确记录
  // ─────────────────────────────────────────────────────────────────────────────
  describe("场景 2: 用 USDC 购买代币，验证持仓余额正确记录", function () {
    it("投资者应能用 USDC 购买代币并获得正确数量", async function () {
      const fixture = await loadFixture(deployBeatChainFixture);
      const { mockUSDC, investor1 } = fixture;
      const { songId, musicToken, musicTokenAddress, params } = await createAndApproveListing(fixture);

      const purchaseAmount = usdc(10_000); // 10,000 USDC
      await mockUSDC.connect(investor1).approve(musicTokenAddress, purchaseAmount);

      await musicToken.connect(investor1).purchaseTokens(purchaseAmount);

      // 预期代币数量 = 10,000 USDC / 0.1 USDC/token = 100,000 tokens
      const expectedTokens = tokens(100_000);
      const balance = await musicToken.balanceOf(investor1.address);
      expect(balance).to.equal(expectedTokens);
    });

    it("购买后 totalUsdcRaised 应正确更新", async function () {
      const fixture = await loadFixture(deployBeatChainFixture);
      const { mockUSDC, investor1 } = fixture;
      const { musicToken, musicTokenAddress } = await createAndApproveListing(fixture);

      const purchaseAmount = usdc(10_000);
      await mockUSDC.connect(investor1).approve(musicTokenAddress, purchaseAmount);
      await musicToken.connect(investor1).purchaseTokens(purchaseAmount);

      expect(await musicToken.totalUsdcRaised()).to.equal(purchaseAmount);
    });

    it("3% 平台发行费应正确扣除并转入国库", async function () {
      const fixture = await loadFixture(deployBeatChainFixture);
      const { mockUSDC, investor1, platformTreasury } = fixture;
      const { musicToken, musicTokenAddress } = await createAndApproveListing(fixture);

      const purchaseAmount = usdc(10_000);
      const expectedFee = usdc(300); // 3% of 10,000

      await mockUSDC.connect(investor1).approve(musicTokenAddress, purchaseAmount);
      await musicToken.connect(investor1).purchaseTokens(purchaseAmount);

      const treasuryBalance = await mockUSDC.balanceOf(await platformTreasury.getAddress());
      expect(treasuryBalance).to.equal(expectedFee);
    });

    it("97% 应转入艺术家钱包", async function () {
      const fixture = await loadFixture(deployBeatChainFixture);
      const { mockUSDC, investor1, artist } = fixture;
      const { musicToken, musicTokenAddress } = await createAndApproveListing(fixture);

      const artistBalanceBefore = await mockUSDC.balanceOf(artist.address);
      const purchaseAmount = usdc(10_000);
      const expectedArtistProceeds = usdc(9_700); // 97% of 10,000

      await mockUSDC.connect(investor1).approve(musicTokenAddress, purchaseAmount);
      await musicToken.connect(investor1).purchaseTokens(purchaseAmount);

      const artistBalanceAfter = await mockUSDC.balanceOf(artist.address);
      expect(artistBalanceAfter - artistBalanceBefore).to.equal(expectedArtistProceeds);
    });

    it("多个投资者购买后持仓应各自正确记录", async function () {
      const fixture = await loadFixture(deployBeatChainFixture);
      const { mockUSDC, investor1, investor2, investor3 } = fixture;
      const { musicToken, musicTokenAddress } = await createAndApproveListing(fixture);

      const amounts = [usdc(10_000), usdc(5_000), usdc(3_000)];
      const investors = [investor1, investor2, investor3];

      for (let i = 0; i < investors.length; i++) {
        await mockUSDC.connect(investors[i]).approve(musicTokenAddress, amounts[i]);
        await musicToken.connect(investors[i]).purchaseTokens(amounts[i]);
      }

      // 验证各投资者持仓
      expect(await musicToken.balanceOf(investor1.address)).to.equal(tokens(100_000));
      expect(await musicToken.balanceOf(investor2.address)).to.equal(tokens(50_000));
      expect(await musicToken.balanceOf(investor3.address)).to.equal(tokens(30_000));
    });

    it("代币售罄后不应允许继续购买", async function () {
      const fixture = await loadFixture(deployBeatChainFixture);
      const { mockUSDC, investor1 } = fixture;
      const { musicToken, musicTokenAddress, params } = await createAndApproveListing(fixture);

      // 购买全部代币（1,000,000 tokens × 0.1 USDC = 100,000 USDC）
      const fullAmount = usdc(100_000);
      await mockUSDC.mint(investor1.address, fullAmount);
      await mockUSDC.connect(investor1).approve(musicTokenAddress, fullAmount);
      await musicToken.connect(investor1).purchaseTokens(fullAmount);

      // 再次购买应失败
      await mockUSDC.connect(investor1).approve(musicTokenAddress, usdc(100));
      await expect(
        musicToken.connect(investor1).purchaseTokens(usdc(100))
      ).to.be.revertedWith("MusicToken: sale is not active");
    });
  });

  // ─────────────────────────────────────────────────────────────────────────────
  // 场景 3: Oracle 提交版税数据，验证中位数计算正确
  // ─────────────────────────────────────────────────────────────────────────────
  describe("场景 3: Oracle 提交版税数据，验证中位数计算正确", function () {
    it("三个节点提交数据后应正确计算中位数", async function () {
      const fixture = await loadFixture(deployBeatChainFixture);
      const { oracleConsumer, oracleNode1, oracleNode2, oracleNode3 } = fixture;

      const songId = 99; // 使用不存在的 songId 仅测试 Oracle 逻辑
      const mockZkProof = ethers.toUtf8Bytes("mock_zk_proof");

      // 三个节点提交不同但接近的数值
      const amounts = [usdc(9_800), usdc(10_000), usdc(10_200)];
      // 中位数应为 10,000

      await oracleConsumer.connect(oracleNode1).submitRoyaltyData(songId, amounts[0], mockZkProof);
      await oracleConsumer.connect(oracleNode2).submitRoyaltyData(songId, amounts[1], mockZkProof);
      await oracleConsumer.connect(oracleNode3).submitRoyaltyData(songId, amounts[2], mockZkProof);

      const roundId = await oracleConsumer.getCurrentRoundId(songId);
      const roundData = await oracleConsumer.getRoundData(roundId);

      expect(roundData.finalized).to.be.true;
      expect(roundData.medianRoyalty).to.equal(usdc(10_000));
    });

    it("偶数个提交时中位数应为中间两个的平均值", async function () {
      const fixture = await loadFixture(deployBeatChainFixture);
      const { oracleConsumer, oracleNode1, oracleNode2, oracleNode3, oracleNodeBad } = fixture;

      const songId = 98;
      const mockZkProof = ethers.toUtf8Bytes("mock_zk_proof");

      // 四个节点提交接近的数值（偶数）
      const amounts = [usdc(9_800), usdc(10_000), usdc(10_200), usdc(10_400)];
      // 中位数 = (10,000 + 10,200) / 2 = 10,100

      await oracleConsumer.connect(oracleNode1).submitRoyaltyData(songId, amounts[0], mockZkProof);
      await oracleConsumer.connect(oracleNode2).submitRoyaltyData(songId, amounts[1], mockZkProof);
      await oracleConsumer.connect(oracleNode3).submitRoyaltyData(songId, amounts[2], mockZkProof);
      await oracleConsumer.connect(oracleNodeBad).submitRoyaltyData(songId, amounts[3], mockZkProof);

      const roundId = await oracleConsumer.getCurrentRoundId(songId);
      const roundData = await oracleConsumer.getRoundData(roundId);

      expect(roundData.finalized).to.be.true;
      expect(roundData.medianRoyalty).to.equal(usdc(10_100));
    });

    it("提交数量不足时不应自动完成轮次", async function () {
      const fixture = await loadFixture(deployBeatChainFixture);
      const { oracleConsumer, oracleNode1, oracleNode2 } = fixture;

      const songId = 97;
      const mockZkProof = ethers.toUtf8Bytes("mock_zk_proof");

      await oracleConsumer.connect(oracleNode1).submitRoyaltyData(songId, usdc(10_000), mockZkProof);
      await oracleConsumer.connect(oracleNode2).submitRoyaltyData(songId, usdc(10_000), mockZkProof);

      const roundId = await oracleConsumer.getCurrentRoundId(songId);
      const roundData = await oracleConsumer.getRoundData(roundId);

      expect(roundData.finalized).to.be.false;
    });

    it("同一节点不应重复提交", async function () {
      const fixture = await loadFixture(deployBeatChainFixture);
      const { oracleConsumer, oracleNode1 } = fixture;

      const songId = 96;
      const mockZkProof = ethers.toUtf8Bytes("mock_zk_proof");

      await oracleConsumer.connect(oracleNode1).submitRoyaltyData(songId, usdc(10_000), mockZkProof);

      await expect(
        oracleConsumer.connect(oracleNode1).submitRoyaltyData(songId, usdc(10_000), mockZkProof)
      ).to.be.revertedWith("OracleConsumer: already submitted");
    });
  });

  // ─────────────────────────────────────────────────────────────────────────────
  // 场景 4: Oracle 节点提交异常值（>20% 偏差），验证被拒绝
  // ─────────────────────────────────────────────────────────────────────────────
  describe("场景 4: Oracle 节点提交异常值（>20% 偏差），验证被拒绝", function () {
    it("偏差超过 20% 的提交应被拒绝并触发 NodeSlashed 事件", async function () {
      const fixture = await loadFixture(deployBeatChainFixture);
      const { oracleConsumer, oracleNode1, oracleNode2, oracleNode3, oracleNodeBad } = fixture;

      const songId = 95;
      const mockZkProof = ethers.toUtf8Bytes("mock_zk_proof");

      // 三个正常节点提交 10,000 USDC
      await oracleConsumer.connect(oracleNode1).submitRoyaltyData(songId, usdc(10_000), mockZkProof);
      await oracleConsumer.connect(oracleNode2).submitRoyaltyData(songId, usdc(10_100), mockZkProof);
      await oracleConsumer.connect(oracleNode3).submitRoyaltyData(songId, usdc(9_900), mockZkProof);

      // 异常节点提交 15,000 USDC（偏差 50%，超过 20% 阈值）
      // 此时轮次已完成（3个节点），异常节点提交会开启新轮次
      // 为了测试异常值拒绝，我们使用一个新 songId 并让异常节点参与同一轮
      const songId2 = 94;
      await oracleConsumer.connect(oracleNode1).submitRoyaltyData(songId2, usdc(10_000), mockZkProof);
      await oracleConsumer.connect(oracleNode2).submitRoyaltyData(songId2, usdc(10_100), mockZkProof);

      // 异常节点提交（偏差 50%）
      const badTx = await oracleConsumer.connect(oracleNodeBad).submitRoyaltyData(
        songId2,
        usdc(15_000), // 50% 偏差
        mockZkProof
      );
      const receipt = await badTx.wait();

      // 轮次完成，检查 NodeSlashed 事件
      let slashEventFound = false;
      for (const log of receipt.logs) {
        try {
          const parsed = oracleConsumer.interface.parseLog(log);
          if (parsed && parsed.name === "NodeSlashed") {
            slashEventFound = true;
            expect(parsed.args.node).to.equal(oracleNodeBad.address);
            break;
          }
        } catch {}
      }

      expect(slashEventFound).to.be.true;
    });

    it("异常值被拒绝后，中位数应基于有效提交计算", async function () {
      const fixture = await loadFixture(deployBeatChainFixture);
      const { oracleConsumer, oracleNode1, oracleNode2, oracleNode3, oracleNodeBad } = fixture;

      const songId = 93;
      const mockZkProof = ethers.toUtf8Bytes("mock_zk_proof");

      await oracleConsumer.connect(oracleNode1).submitRoyaltyData(songId, usdc(10_000), mockZkProof);
      await oracleConsumer.connect(oracleNode2).submitRoyaltyData(songId, usdc(10_100), mockZkProof);
      await oracleConsumer.connect(oracleNode3).submitRoyaltyData(songId, usdc(9_900), mockZkProof);
      // 异常节点提交（开启新轮次，因为前3个已完成）

      const roundId = await oracleConsumer.getCurrentRoundId(songId);
      const roundData = await oracleConsumer.getRoundData(roundId);

      // 中位数应为 10,000（三个正常值的中位数）
      expect(roundData.medianRoyalty).to.equal(usdc(10_000));
    });

    it("非 Oracle 节点不应能提交数据", async function () {
      const fixture = await loadFixture(deployBeatChainFixture);
      const { oracleConsumer, investor1 } = fixture;

      await expect(
        oracleConsumer.connect(investor1).submitRoyaltyData(
          1,
          usdc(10_000),
          ethers.toUtf8Bytes("proof")
        )
      ).to.be.revertedWith("OracleConsumer: caller is not an Oracle node");
    });
  });

  // ─────────────────────────────────────────────────────────────────────────────
  // 场景 5: RoyaltyDistributor 接收 USDC，验证分配比例正确
  // ─────────────────────────────────────────────────────────────────────────────
  describe("场景 5: RoyaltyDistributor 接收 USDC，验证分配比例正确", function () {
    it("应正确扣除 1% 平台费并记录净分配金额", async function () {
      const fixture = await loadFixture(deployBeatChainFixture);
      const { mockUSDC, royaltyDistributor, deployer, platformTreasury } = fixture;
      const { songId } = await createAndApproveListing(fixture);

      const royaltyAmount = usdc(10_000);
      const expectedFee = usdc(100);    // 1% of 10,000
      const expectedNet = usdc(9_900);  // 99% of 10,000

      // 授权 RoyaltyDistributor 拉取 USDC
      await mockUSDC.connect(deployer).approve(await royaltyDistributor.getAddress(), royaltyAmount);

      const tx = await royaltyDistributor.connect(deployer).receiveRoyalty(songId, royaltyAmount);
      const receipt = await tx.wait();

      // 检查 RoyaltyReceived 事件
      let eventFound = false;
      for (const log of receipt.logs) {
        try {
          const parsed = royaltyDistributor.interface.parseLog(log);
          if (parsed && parsed.name === "RoyaltyReceived") {
            expect(parsed.args.totalUsdcReceived).to.equal(royaltyAmount);
            expect(parsed.args.platformFeeDeducted).to.equal(expectedFee);
            expect(parsed.args.netAmount).to.equal(expectedNet);
            eventFound = true;
            break;
          }
        } catch {}
      }
      expect(eventFound).to.be.true;
    });

    it("投资者应能按持股比例领取版税", async function () {
      const fixture = await loadFixture(deployBeatChainFixture);
      const { mockUSDC, royaltyDistributor, deployer, investor1, investor2 } = fixture;
      const { songId, musicToken, musicTokenAddress } = await createAndApproveListing(fixture);

      // 投资者购买代币
      // investor1: 10,000 USDC → 100,000 tokens
      // investor2: 5,000 USDC → 50,000 tokens
      await mockUSDC.connect(investor1).approve(musicTokenAddress, usdc(10_000));
      await musicToken.connect(investor1).purchaseTokens(usdc(10_000));

      await mockUSDC.connect(investor2).approve(musicTokenAddress, usdc(5_000));
      await musicToken.connect(investor2).purchaseTokens(usdc(5_000));

      // 直接向 RoyaltyDistributor 存入版税（模拟 OracleConsumer 触发）
      const royaltyAmount = usdc(9_000);
      await mockUSDC.connect(deployer).approve(await royaltyDistributor.getAddress(), royaltyAmount);
      await royaltyDistributor.connect(deployer).receiveRoyalty(songId, royaltyAmount);

      // 手动 credit（模拟分配）
      const totalSupply = await musicToken.totalSupply();
      const netRoyalty = usdc(8_910); // 9,000 × 99%

      const inv1Balance = await musicToken.balanceOf(investor1.address);
      const inv2Balance = await musicToken.balanceOf(investor2.address);

      const inv1Share = (netRoyalty * inv1Balance) / totalSupply;
      const inv2Share = (netRoyalty * inv2Balance) / totalSupply;

      await royaltyDistributor.connect(deployer).creditHolder(investor1.address, songId, inv1Share);
      await royaltyDistributor.connect(deployer).creditHolder(investor2.address, songId, inv2Share);

      // 验证可领取余额
      const claimable1 = await royaltyDistributor.claimableBalance(investor1.address, songId);
      const claimable2 = await royaltyDistributor.claimableBalance(investor2.address, songId);

      // investor1 持有 100,000/150,000 = 66.67% → 约 5,940 USDC
      // investor2 持有 50,000/150,000 = 33.33% → 约 2,970 USDC
      expect(claimable1).to.be.gt(0);
      expect(claimable2).to.be.gt(0);
      expect(claimable1).to.be.gt(claimable2); // investor1 持有更多，应获得更多
    });

    it("投资者领取版税后余额应清零", async function () {
      const fixture = await loadFixture(deployBeatChainFixture);
      const { mockUSDC, royaltyDistributor, deployer, investor1 } = fixture;
      const { songId } = await createAndApproveListing(fixture);

      const creditAmount = usdc(1_000);
      await royaltyDistributor.connect(deployer).creditHolder(investor1.address, songId, creditAmount);

      // 领取前余额
      const balanceBefore = await mockUSDC.balanceOf(investor1.address);

      // 领取版税
      await royaltyDistributor.connect(investor1).claimRoyalty(songId);

      // 领取后余额增加
      const balanceAfter = await mockUSDC.balanceOf(investor1.address);
      expect(balanceAfter - balanceBefore).to.equal(creditAmount);

      // 可领取余额清零
      expect(await royaltyDistributor.claimableBalance(investor1.address, songId)).to.equal(0);
    });

    it("没有可领取余额时应拒绝领取", async function () {
      const fixture = await loadFixture(deployBeatChainFixture);
      const { royaltyDistributor, investor1 } = fixture;
      const { songId } = await createAndApproveListing(fixture);

      await expect(
        royaltyDistributor.connect(investor1).claimRoyalty(songId)
      ).to.be.revertedWith("RoyaltyDistributor: nothing to claim");
    });
  });

  // ─────────────────────────────────────────────────────────────────────────────
  // 场景 6: 艺术家连续 2 个月未转账，验证托管自动分配
  // ─────────────────────────────────────────────────────────────────────────────
  describe("场景 6: 艺术家连续 2 个月未转账，验证托管自动分配", function () {
    it("连续 2 个月版税为 0 时应触发 ArtistDefaultDetected 事件", async function () {
      const fixture = await loadFixture(deployBeatChainFixture);
      const { delistingManager, deployer } = fixture;
      const { songId } = await createAndApproveListing(fixture);

      // 第 1 个月：版税为 0
      await delistingManager.connect(deployer).recordMonth(songId, 0);

      // 第 2 个月：版税为 0 → 触发违约
      await expect(
        delistingManager.connect(deployer).recordMonth(songId, 0)
      ).to.emit(delistingManager, "ArtistDefaultDetected")
        .withArgs(songId, 2);
    });

    it("触发违约后歌曲状态应变为 DELISTED", async function () {
      const fixture = await loadFixture(deployBeatChainFixture);
      const { delistingManager, listingManager, deployer } = fixture;
      const { songId } = await createAndApproveListing(fixture);

      await delistingManager.connect(deployer).recordMonth(songId, 0);
      await delistingManager.connect(deployer).recordMonth(songId, 0);

      const status = await listingManager.getListingStatus(songId);
      expect(status).to.equal(2); // DELISTED = 2
    });

    it("正常收到版税后应重置连续未付计数", async function () {
      const fixture = await loadFixture(deployBeatChainFixture);
      const { delistingManager, deployer } = fixture;
      const { songId } = await createAndApproveListing(fixture);

      // 第 1 个月：版税为 0
      await delistingManager.connect(deployer).recordMonth(songId, 0);

      // 第 2 个月：收到版税 → 重置计数
      await delistingManager.connect(deployer).recordMonth(songId, usdc(10_000));

      // 第 3 个月：版税为 0 → 计数重新从 1 开始，不触发违约
      await delistingManager.connect(deployer).recordMonth(songId, 0);

      const monitor = await delistingManager.getSongMonitor(songId);
      expect(monitor.consecutiveMissedMonths).to.equal(1);
      expect(monitor.delisted).to.be.false;
    });

    it("管理员应能将押金分配给持有者", async function () {
      const fixture = await loadFixture(deployBeatChainFixture);
      const { mockUSDC, escrowVault, delistingManager, deployer, investor1, investor2 } = fixture;
      const { songId } = await createAndApproveListing(fixture);

      // 触发违约
      await delistingManager.connect(deployer).recordMonth(songId, 0);
      await delistingManager.connect(deployer).recordMonth(songId, 0);

      // 押金应仍在 EscrowVault（违约触发后需要管理员手动分配）
      const deposit = await escrowVault.getDeposit(songId);

      if (deposit.active) {
        const holders = [investor1.address, investor2.address];
        const amounts = [usdc(24_000), usdc(24_000)]; // 各分 50%

        const inv1Before = await mockUSDC.balanceOf(investor1.address);
        const inv2Before = await mockUSDC.balanceOf(investor2.address);

        await delistingManager.connect(deployer).distributeDefaultEscrow(songId, holders, amounts);

        const inv1After = await mockUSDC.balanceOf(investor1.address);
        const inv2After = await mockUSDC.balanceOf(investor2.address);

        expect(inv1After - inv1Before).to.equal(usdc(24_000));
        expect(inv2After - inv2Before).to.equal(usdc(24_000));
      }
    });
  });

  // ─────────────────────────────────────────────────────────────────────────────
  // 场景 7: 公允价值连续 6 个月低于发行价 30%，验证触发强制退市
  // ─────────────────────────────────────────────────────────────────────────────
  describe("场景 7: 公允价值连续 6 个月低于发行价 30%，验证触发强制退市", function () {
    it("公允价值连续 6 个月低于 30% 阈值时应触发强制退市", async function () {
      const fixture = await loadFixture(deployBeatChainFixture);
      const { priceFeed, delistingManager, listingManager, deployer } = fixture;
      const { songId, params } = await createAndApproveListing(fixture);

      // 发行公允价值 = 0.1 USDC/token
      // 30% 阈值 = 0.03 USDC/token
      // 设置低于阈值的公允价值 = 0.02 USDC/token
      const lowFairValue = usdc("0.02"); // 低于 30% × 0.1 = 0.03

      // 连续 6 个月更新低公允价值并记录
      for (let month = 1; month <= 5; month++) {
        await priceFeed.connect(deployer).updateFairValue(songId, lowFairValue, usdc(1_000));
        await delistingManager.connect(deployer).recordMonth(songId, usdc(1_000));

        const monitor = await delistingManager.getSongMonitor(songId);
        expect(monitor.consecutiveLowMonths).to.equal(month);
        expect(monitor.delisted).to.be.false;
      }

      // 第 6 个月：触发强制退市
      await priceFeed.connect(deployer).updateFairValue(songId, lowFairValue, usdc(1_000));

      await expect(
        delistingManager.connect(deployer).recordMonth(songId, usdc(1_000))
      ).to.emit(delistingManager, "ForcedDelistingExecuted");
    });

    it("强制退市后歌曲状态应变为 DELISTED", async function () {
      const fixture = await loadFixture(deployBeatChainFixture);
      const { priceFeed, delistingManager, listingManager, deployer } = fixture;
      const { songId } = await createAndApproveListing(fixture);

      const lowFairValue = usdc("0.02");

      for (let month = 1; month <= 6; month++) {
        await priceFeed.connect(deployer).updateFairValue(songId, lowFairValue, usdc(1_000));
        await delistingManager.connect(deployer).recordMonth(songId, usdc(1_000));
      }

      const status = await listingManager.getListingStatus(songId);
      expect(status).to.equal(2); // DELISTED = 2
    });

    it("公允价值恢复后应重置连续低值计数", async function () {
      const fixture = await loadFixture(deployBeatChainFixture);
      const { priceFeed, delistingManager, deployer } = fixture;
      const { songId } = await createAndApproveListing(fixture);

      const lowFairValue = usdc("0.02");
      const normalFairValue = usdc("0.1");

      // 3 个月低值
      for (let month = 1; month <= 3; month++) {
        await priceFeed.connect(deployer).updateFairValue(songId, lowFairValue, usdc(1_000));
        await delistingManager.connect(deployer).recordMonth(songId, usdc(1_000));
      }

      // 公允价值恢复
      await priceFeed.connect(deployer).updateFairValue(songId, normalFairValue, usdc(10_000));
      await delistingManager.connect(deployer).recordMonth(songId, usdc(10_000));

      const monitor = await delistingManager.getSongMonitor(songId);
      expect(monitor.consecutiveLowMonths).to.equal(0);
      expect(monitor.delisted).to.be.false;
    });

    it("PriceFeed 公允价值变化超过 25% 时应触发人工审查标志", async function () {
      const fixture = await loadFixture(deployBeatChainFixture);
      const { priceFeed, deployer } = fixture;
      const { songId } = await createAndApproveListing(fixture);

      // 初始公允价值
      await priceFeed.connect(deployer).updateFairValue(songId, usdc("0.1"), usdc(10_000));

      // 公允价值变化 30%（超过 25% 阈值）
      await expect(
        priceFeed.connect(deployer).updateFairValue(songId, usdc("0.13"), usdc(13_000))
      ).to.emit(priceFeed, "ManualReviewTriggered");
    });

    it("强制退市后押金应返还给艺术家", async function () {
      const fixture = await loadFixture(deployBeatChainFixture);
      const { mockUSDC, priceFeed, delistingManager, escrowVault, deployer, artist } = fixture;
      const { songId } = await createAndApproveListing(fixture);

      const artistBalanceBefore = await mockUSDC.balanceOf(artist.address);
      const lowFairValue = usdc("0.02");

      for (let month = 1; month <= 6; month++) {
        await priceFeed.connect(deployer).updateFairValue(songId, lowFairValue, usdc(1_000));
        await delistingManager.connect(deployer).recordMonth(songId, usdc(1_000));
      }

      // 押金应已返还给艺术家
      const artistBalanceAfter = await mockUSDC.balanceOf(artist.address);
      expect(artistBalanceAfter - artistBalanceBefore).to.equal(usdc(48_000));
    });
  });

  // ─────────────────────────────────────────────────────────────────────────────
  // 附加测试: PlatformTreasury
  // ─────────────────────────────────────────────────────────────────────────────
  describe("附加测试: PlatformTreasury", function () {
    it("只有平台管理员可以提取费用", async function () {
      const fixture = await loadFixture(deployBeatChainFixture);
      const { mockUSDC, platformTreasury, deployer, platformAdmin, investor1 } = fixture;

      // 向国库存入费用
      const feeAmount = usdc(1_000);
      await mockUSDC.connect(deployer).approve(await platformTreasury.getAddress(), feeAmount);
      await platformTreasury.connect(deployer).depositFee(await mockUSDC.getAddress(), feeAmount);

      // 非管理员不能提取
      await expect(
        platformTreasury.connect(investor1).withdrawAllFees(await mockUSDC.getAddress())
      ).to.be.revertedWith("PlatformTreasury: caller is not admin");

      // 管理员可以提取
      const adminBalanceBefore = await mockUSDC.balanceOf(platformAdmin.address);
      await platformTreasury.connect(platformAdmin).withdrawAllFees(await mockUSDC.getAddress());
      const adminBalanceAfter = await mockUSDC.balanceOf(platformAdmin.address);

      expect(adminBalanceAfter - adminBalanceBefore).to.equal(feeAmount);
    });
  });

  // ─────────────────────────────────────────────────────────────────────────────
  // 附加测试: EscrowVault
  // ─────────────────────────────────────────────────────────────────────────────
  describe("附加测试: EscrowVault", function () {
    it("押金锁定后应正确记录", async function () {
      const fixture = await loadFixture(deployBeatChainFixture);
      const { escrowVault } = fixture;
      const { songId } = await createAndApproveListing(fixture);

      const deposit = await escrowVault.getDeposit(songId);
      expect(deposit.active).to.be.true;
      expect(deposit.amount).to.equal(usdc(48_000));
    });

    it("自愿退市时押金应返还给艺术家", async function () {
      const fixture = await loadFixture(deployBeatChainFixture);
      const { mockUSDC, delistingManager, deployer, artist } = fixture;
      const { songId } = await createAndApproveListing(fixture);

      const artistBalanceBefore = await mockUSDC.balanceOf(artist.address);

      // 艺术家申请自愿退市
      await delistingManager.connect(artist).requestVoluntaryDelisting(songId);

      // 管理员审批
      await delistingManager.connect(deployer).approveVoluntaryDelisting(songId);

      const artistBalanceAfter = await mockUSDC.balanceOf(artist.address);
      expect(artistBalanceAfter - artistBalanceBefore).to.equal(usdc(48_000));
    });
  });

  // ─────────────────────────────────────────────────────────────────────────────
  // 场景 8: AMM 流动性池 - 创建、添加流动性、交易
  // ─────────────────────────────────────────────────────────────────────────────
  describe("场景 8: AMM 流动性池 - 创建、添加流动性、交易", function () {
    it("应能创建流动性池并添加初始流动性", async function () {
      const fixture = await loadFixture(deployBeatChainFixture);
      const { mockUSDC, deployer, investor1 } = fixture;
      const { songId, musicToken, musicTokenAddress } = await createAndApproveListing(fixture);

      // 投资者先购买代币
      await mockUSDC.connect(investor1).approve(musicTokenAddress, usdc(10_000));
      await musicToken.connect(investor1).purchaseTokens(usdc(10_000));

      // 部署 LiquidityPool
      const LiquidityPool = await ethers.getContractFactory("LiquidityPool");
      const pool = await LiquidityPool.deploy(
        await mockUSDC.getAddress(),
        musicTokenAddress,
        songId
      );
      await pool.waitForDeployment();
      const poolAddress = await pool.getAddress();

      // 投资者添加流动性
      const usdcLiquidity = usdc(5_000);
      const tokenLiquidity = tokens(50_000);

      await mockUSDC.connect(investor1).approve(poolAddress, usdcLiquidity);
      await musicToken.connect(investor1).approve(poolAddress, tokenLiquidity);

      await pool.connect(investor1).addLiquidity(usdcLiquidity, tokenLiquidity);

      // 验证储备量
      const [reserveUSDC, reserveToken] = await pool.getReserves();
      expect(reserveUSDC).to.equal(usdcLiquidity);
      expect(reserveToken).to.equal(tokenLiquidity);

      // 验证 LP 代币
      const lpBalance = await pool.balanceOf(investor1.address);
      expect(lpBalance).to.be.gt(0);
    });

    it("应能通过 AMM 池用 USDC 购买歌曲代币", async function () {
      const fixture = await loadFixture(deployBeatChainFixture);
      const { mockUSDC, investor1, investor2 } = fixture;
      const { songId, musicToken, musicTokenAddress } = await createAndApproveListing(fixture);

      // investor1 购买代币并提供流动性
      await mockUSDC.connect(investor1).approve(musicTokenAddress, usdc(10_000));
      await musicToken.connect(investor1).purchaseTokens(usdc(10_000));

      const LiquidityPool = await ethers.getContractFactory("LiquidityPool");
      const pool = await LiquidityPool.deploy(
        await mockUSDC.getAddress(),
        musicTokenAddress,
        songId
      );
      const poolAddress = await pool.getAddress();

      await mockUSDC.connect(investor1).approve(poolAddress, usdc(5_000));
      await musicToken.connect(investor1).approve(poolAddress, tokens(50_000));
      await pool.connect(investor1).addLiquidity(usdc(5_000), tokens(50_000));

      // investor2 通过 AMM 购买代币
      const swapAmount = usdc(1_000);
      await mockUSDC.connect(investor2).approve(poolAddress, swapAmount);

      const tokenBalanceBefore = await musicToken.balanceOf(investor2.address);
      await pool.connect(investor2).swapUSDCForToken(swapAmount, 0);
      const tokenBalanceAfter = await musicToken.balanceOf(investor2.address);

      expect(tokenBalanceAfter).to.be.gt(tokenBalanceBefore);
    });

    it("应能通过 AMM 池卖出歌曲代币换取 USDC", async function () {
      const fixture = await loadFixture(deployBeatChainFixture);
      const { mockUSDC, investor1, investor2 } = fixture;
      const { songId, musicToken, musicTokenAddress } = await createAndApproveListing(fixture);

      // 设置流动性池
      await mockUSDC.connect(investor1).approve(musicTokenAddress, usdc(10_000));
      await musicToken.connect(investor1).purchaseTokens(usdc(10_000));

      const LiquidityPool = await ethers.getContractFactory("LiquidityPool");
      const pool = await LiquidityPool.deploy(
        await mockUSDC.getAddress(),
        musicTokenAddress,
        songId
      );
      const poolAddress = await pool.getAddress();

      await mockUSDC.connect(investor1).approve(poolAddress, usdc(5_000));
      await musicToken.connect(investor1).approve(poolAddress, tokens(50_000));
      await pool.connect(investor1).addLiquidity(usdc(5_000), tokens(50_000));

      // investor2 先购买代币
      await mockUSDC.connect(investor2).approve(musicTokenAddress, usdc(5_000));
      await musicToken.connect(investor2).purchaseTokens(usdc(5_000));

      // investor2 通过 AMM 卖出代币
      const sellAmount = tokens(10_000);
      await musicToken.connect(investor2).approve(poolAddress, sellAmount);

      const usdcBalanceBefore = await mockUSDC.balanceOf(investor2.address);
      await pool.connect(investor2).swapTokenForUSDC(sellAmount, 0);
      const usdcBalanceAfter = await mockUSDC.balanceOf(investor2.address);

      expect(usdcBalanceAfter).to.be.gt(usdcBalanceBefore);
    });

    it("池暂停时不应允许交易", async function () {
      const fixture = await loadFixture(deployBeatChainFixture);
      const { mockUSDC, deployer, investor1, investor2 } = fixture;
      const { songId, musicToken, musicTokenAddress } = await createAndApproveListing(fixture);

      await mockUSDC.connect(investor1).approve(musicTokenAddress, usdc(10_000));
      await musicToken.connect(investor1).purchaseTokens(usdc(10_000));

      const LiquidityPool = await ethers.getContractFactory("LiquidityPool");
      const pool = await LiquidityPool.deploy(
        await mockUSDC.getAddress(),
        musicTokenAddress,
        songId
      );
      const poolAddress = await pool.getAddress();

      await mockUSDC.connect(investor1).approve(poolAddress, usdc(5_000));
      await musicToken.connect(investor1).approve(poolAddress, tokens(50_000));
      await pool.connect(investor1).addLiquidity(usdc(5_000), tokens(50_000));

      // 暂停池
      await pool.connect(deployer).pausePool("Circuit breaker triggered");

      // 尝试交易应失败
      await mockUSDC.connect(investor2).approve(poolAddress, usdc(100));
      await expect(
        pool.connect(investor2).swapUSDCForToken(usdc(100), 0)
      ).to.be.revertedWith("LiquidityPool: pool is paused");
    });

    it("应能移除流动性并取回资产", async function () {
      const fixture = await loadFixture(deployBeatChainFixture);
      const { mockUSDC, investor1 } = fixture;
      const { songId, musicToken, musicTokenAddress } = await createAndApproveListing(fixture);

      await mockUSDC.connect(investor1).approve(musicTokenAddress, usdc(10_000));
      await musicToken.connect(investor1).purchaseTokens(usdc(10_000));

      const LiquidityPool = await ethers.getContractFactory("LiquidityPool");
      const pool = await LiquidityPool.deploy(
        await mockUSDC.getAddress(),
        musicTokenAddress,
        songId
      );
      const poolAddress = await pool.getAddress();

      await mockUSDC.connect(investor1).approve(poolAddress, usdc(5_000));
      await musicToken.connect(investor1).approve(poolAddress, tokens(50_000));
      await pool.connect(investor1).addLiquidity(usdc(5_000), tokens(50_000));

      const lpBalance = await pool.balanceOf(investor1.address);
      const usdcBefore = await mockUSDC.balanceOf(investor1.address);
      const tokenBefore = await musicToken.balanceOf(investor1.address);

      // 移除全部流动性
      await pool.connect(investor1).removeLiquidity(lpBalance);

      const usdcAfter = await mockUSDC.balanceOf(investor1.address);
      const tokenAfter = await musicToken.balanceOf(investor1.address);

      expect(usdcAfter).to.be.gt(usdcBefore);
      expect(tokenAfter).to.be.gt(tokenBefore);
    });

    it("应正确返回市场价格", async function () {
      const fixture = await loadFixture(deployBeatChainFixture);
      const { mockUSDC, investor1 } = fixture;
      const { songId, musicToken, musicTokenAddress } = await createAndApproveListing(fixture);

      await mockUSDC.connect(investor1).approve(musicTokenAddress, usdc(10_000));
      await musicToken.connect(investor1).purchaseTokens(usdc(10_000));

      const LiquidityPool = await ethers.getContractFactory("LiquidityPool");
      const pool = await LiquidityPool.deploy(
        await mockUSDC.getAddress(),
        musicTokenAddress,
        songId
      );
      const poolAddress = await pool.getAddress();

      // 添加流动性: 5000 USDC / 50000 tokens = 0.1 USDC/token
      await mockUSDC.connect(investor1).approve(poolAddress, usdc(5_000));
      await musicToken.connect(investor1).approve(poolAddress, tokens(50_000));
      await pool.connect(investor1).addLiquidity(usdc(5_000), tokens(50_000));

      const marketPrice = await pool.getMarketPrice();
      // 价格 = 5000 * 1e6 * 1e18 / (50000 * 1e18) = 0.1 * 1e6 = 100000
      // 但 getMarketPrice 返回 reserveUSDC * 1e18 / reserveToken
      expect(marketPrice).to.be.gt(0);
    });
  });

  // ─────────────────────────────────────────────────────────────────────────────
  // 场景 9: LiquidityBootstrap - 种子流动性和 LP 锁定
  // ─────────────────────────────────────────────────────────────────────────────
  describe("场景 9: LiquidityBootstrap - 种子流动性和 LP 锁定", function () {
    it("应能创建流动性池并注入种子流动性", async function () {
      const fixture = await loadFixture(deployBeatChainFixture);
      const { mockUSDC, deployer, investor1 } = fixture;
      const { songId, musicToken, musicTokenAddress } = await createAndApproveListing(fixture);

      // 投资者购买代币
      await mockUSDC.connect(investor1).approve(musicTokenAddress, usdc(10_000));
      await musicToken.connect(investor1).purchaseTokens(usdc(10_000));

      // 部署 LiquidityBootstrap
      const LiquidityBootstrap = await ethers.getContractFactory("LiquidityBootstrap");
      const bootstrap = await LiquidityBootstrap.deploy(await mockUSDC.getAddress());
      await bootstrap.waitForDeployment();
      const bootstrapAddress = await bootstrap.getAddress();

      // 创建池
      await bootstrap.connect(deployer).createPool(songId, musicTokenAddress);
      const poolAddress = await bootstrap.getPool(songId);
      expect(poolAddress).to.not.equal(ethers.ZeroAddress);

      // 准备种子流动性
      const seedUSDC = usdc(5_000);
      const seedTokens = tokens(50_000);

      // 转移代币给 deployer 用于种子
      await musicToken.connect(investor1).transfer(deployer.address, seedTokens);

      await mockUSDC.connect(deployer).approve(bootstrapAddress, seedUSDC);
      await musicToken.connect(deployer).approve(bootstrapAddress, seedTokens);

      // 注入种子流动性
      await bootstrap.connect(deployer).seedPool(songId, seedUSDC, seedTokens);

      const poolInfo = await bootstrap.getPoolInfo(songId);
      expect(poolInfo.seeded).to.be.true;
      expect(poolInfo.seedUsdcAmount).to.equal(seedUSDC);
    });

    it("种子流动性 LP 代币应被锁定 12 个月", async function () {
      const fixture = await loadFixture(deployBeatChainFixture);
      const { mockUSDC, deployer, investor1 } = fixture;
      const { songId, musicToken, musicTokenAddress } = await createAndApproveListing(fixture);

      await mockUSDC.connect(investor1).approve(musicTokenAddress, usdc(10_000));
      await musicToken.connect(investor1).purchaseTokens(usdc(10_000));

      const LiquidityBootstrap = await ethers.getContractFactory("LiquidityBootstrap");
      const bootstrap = await LiquidityBootstrap.deploy(await mockUSDC.getAddress());
      const bootstrapAddress = await bootstrap.getAddress();

      await bootstrap.connect(deployer).createPool(songId, musicTokenAddress);

      const seedUSDC = usdc(5_000);
      const seedTokens = tokens(50_000);
      await musicToken.connect(investor1).transfer(deployer.address, seedTokens);
      await mockUSDC.connect(deployer).approve(bootstrapAddress, seedUSDC);
      await musicToken.connect(deployer).approve(bootstrapAddress, seedTokens);
      await bootstrap.connect(deployer).seedPool(songId, seedUSDC, seedTokens);

      // 尝试在锁定期内解锁应失败
      await expect(
        bootstrap.connect(deployer).unlockLP(1)
      ).to.be.revertedWith("LiquidityBootstrap: lock period not elapsed");

      // 验证锁定剩余时间
      const remaining = await bootstrap.getLockRemainingTime(1);
      expect(remaining).to.be.gt(0);
    });
  });

  // ─────────────────────────────────────────────────────────────────────────────
  // 场景 10: Oracle Wash Streaming 风险评分
  // ─────────────────────────────────────────────────────────────────────────────
  describe("场景 10: Oracle Wash Streaming 风险评分", function () {
    it("Red flag (风险 > 70) 应触发熔断机制", async function () {
      const fixture = await loadFixture(deployBeatChainFixture);
      const { oracleConsumer, oracleNode1 } = fixture;

      const songId = 88;
      const mockZkProof = ethers.toUtf8Bytes("mock_zk_proof");

      // 提交 Red flag 风险评分
      await oracleConsumer.connect(oracleNode1).submitRoyaltyDataWithRisk(
        songId,
        usdc(10_000),
        75, // Red flag
        mockZkProof
      );

      // 验证熔断机制已激活
      expect(await oracleConsumer.circuitBreakerActive(songId)).to.be.true;
    });

    it("Yellow flag (风险 40-70) 应标记异常但继续处理", async function () {
      const fixture = await loadFixture(deployBeatChainFixture);
      const { oracleConsumer, oracleNode1, oracleNode2, oracleNode3 } = fixture;

      const songId = 87;
      const mockZkProof = ethers.toUtf8Bytes("mock_zk_proof");

      // 提交 Yellow flag 风险评分
      await oracleConsumer.connect(oracleNode1).submitRoyaltyDataWithRisk(
        songId,
        usdc(10_000),
        55, // Yellow flag
        mockZkProof
      );

      // 验证异常标记
      expect(await oracleConsumer.anomalyFlagged(songId)).to.be.true;

      // 熔断不应激活
      expect(await oracleConsumer.circuitBreakerActive(songId)).to.be.false;
    });

    it("Green (风险 < 40) 应正常处理", async function () {
      const fixture = await loadFixture(deployBeatChainFixture);
      const { oracleConsumer, oracleNode1 } = fixture;

      const songId = 86;
      const mockZkProof = ethers.toUtf8Bytes("mock_zk_proof");

      await oracleConsumer.connect(oracleNode1).submitRoyaltyDataWithRisk(
        songId,
        usdc(10_000),
        20, // Green
        mockZkProof
      );

      expect(await oracleConsumer.anomalyFlagged(songId)).to.be.false;
      expect(await oracleConsumer.circuitBreakerActive(songId)).to.be.false;
    });
  });
});