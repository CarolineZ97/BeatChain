// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "./LiquidityPool.sol";

/**
 * @title LiquidityBootstrap
 * @notice 流动性引导合约，负责为每首歌曲的 AMM 池提供初始流动性。
 *
 * 三层流动性引导机制:
 *  1. 平台种子流动性: 平台贡献融资金额的 5-10% USDC，锁定 12 个月
 *  2. 艺术家流动性激励: 艺术家承诺 10% 融资额到流动性池，可享受发行费折扣（3% → 2%）
 *  3. 外部 LP 费用奖励: 第三方 LP 提供者赚取 0.3% 交易手续费
 *
 * 功能:
 *  - seedPool(): 平台注入种子流动性
 *  - lockLP(): 锁定 LP 代币
 *  - unlockAfterPeriod(): 锁定期满后解锁
 *  - applyArtistDiscount(): 应用艺术家 LP 折扣
 */
contract LiquidityBootstrap is Ownable, ReentrancyGuard {
    // ─── Constants ─────────────────────────────────────────────────────────────

    /// @notice 平台种子流动性最小比例（融资额的 5%）
    uint256 public constant MIN_SEED_RATIO_BPS = 500;

    /// @notice 平台种子流动性最大比例（融资额的 10%）
    uint256 public constant MAX_SEED_RATIO_BPS = 1000;

    /// @notice 平台种子流动性锁定期（12 个月）
    uint256 public constant PLATFORM_LOCK_PERIOD = 365 days;

    /// @notice 艺术家 LP 最小锁定期（6 个月）
    uint256 public constant ARTIST_LOCK_PERIOD = 180 days;

    /// @notice 艺术家 LP 承诺比例（融资额的 10%）
    uint256 public constant ARTIST_LP_RATIO_BPS = 1000;

    /// @notice 正常发行费（3%）
    uint256 public constant NORMAL_ISSUANCE_FEE_BPS = 300;

    /// @notice 折扣发行费（2%）
    uint256 public constant DISCOUNTED_ISSUANCE_FEE_BPS = 200;

    /// @notice Basis points 分母
    uint256 public constant BPS_DENOMINATOR = 10000;

    // ─── Structs ───────────────────────────────────────────────────────────────

    struct LPLock {
        address owner;           // LP 代币持有者
        address pool;            // LiquidityPool 合约地址
        uint256 lpAmount;        // 锁定的 LP 代币数量
        uint256 lockedAt;        // 锁定时间戳
        uint256 lockDuration;    // 锁定时长
        bool released;           // 是否已释放
        LockType lockType;       // 锁定类型
    }

    enum LockType { PLATFORM_SEED, ARTIST_LP, EXTERNAL_LP }

    struct PoolInfo {
        address pool;            // LiquidityPool 合约地址
        uint256 songId;          // 歌曲 ID
        uint256 seedUsdcAmount;  // 平台种子 USDC 数量
        uint256 seedTokenAmount; // 平台种子代币数量
        bool seeded;             // 是否已注入种子流动性
        bool artistLPCommitted;  // 艺术家是否已承诺 LP
    }

    // ─── Events ───────────────────────────────────────────────────────────────

    event PoolSeeded(
        uint256 indexed songId,
        address indexed pool,
        uint256 usdcAmount,
        uint256 tokenAmount,
        uint256 lpTokens
    );
    event LPLocked(
        uint256 indexed lockId,
        address indexed owner,
        uint256 lpAmount,
        uint256 lockDuration,
        LockType lockType
    );
    event LPUnlocked(
        uint256 indexed lockId,
        address indexed owner,
        uint256 lpAmount
    );
    event ArtistLPCommitted(
        uint256 indexed songId,
        address indexed artist,
        uint256 usdcAmount,
        uint256 tokenAmount
    );
    event ArtistDiscountApplied(
        uint256 indexed songId,
        address indexed artist,
        uint256 discountBps
    );
    event PoolCreated(
        uint256 indexed songId,
        address indexed pool
    );

    // ─── State Variables ───────────────────────────────────────────────────────

    /// @notice USDC 代币合约
    IERC20 public immutable usdc;

    /// @notice 歌曲 ID => 池信息
    mapping(uint256 => PoolInfo) public poolInfos;

    /// @notice LP 锁定记录
    mapping(uint256 => LPLock) public lpLocks;

    /// @notice 总锁定记录数
    uint256 public totalLocks;

    /// @notice 歌曲 ID => LiquidityPool 地址
    mapping(uint256 => address) public songPools;

    /// @notice 艺术家是否已承诺 LP（songId => committed）
    mapping(uint256 => bool) public artistLPCommitted;

    /// @notice 艺术家 LP 折扣资格（songId => eligible）
    mapping(uint256 => bool) public artistDiscountEligible;

    // ─── Constructor ───────────────────────────────────────────────────────────

    /**
     * @param _usdc USDC ERC-20 合约地址
     */
    constructor(address _usdc) Ownable(msg.sender) {
        require(_usdc != address(0), "LiquidityBootstrap: invalid USDC");
        usdc = IERC20(_usdc);
    }

    // ─── External Functions ────────────────────────────────────────────────────

    /**
     * @notice 为歌曲创建流动性池
     * @param songId     歌曲 ID
     * @param songToken  歌曲代币合约地址
     * @return pool      新创建的 LiquidityPool 地址
     */
    function createPool(
        uint256 songId,
        address songToken
    ) external onlyOwner returns (address pool) {
        require(songPools[songId] == address(0), "LiquidityBootstrap: pool already exists");
        require(songToken != address(0), "LiquidityBootstrap: invalid song token");

        LiquidityPool newPool = new LiquidityPool(
            address(usdc),
            songToken,
            songId
        );

        pool = address(newPool);
        songPools[songId] = pool;

        poolInfos[songId] = PoolInfo({
            pool: pool,
            songId: songId,
            seedUsdcAmount: 0,
            seedTokenAmount: 0,
            seeded: false,
            artistLPCommitted: false
        });

        emit PoolCreated(songId, pool);
    }

    /**
     * @notice 平台注入种子流动性（锁定 12 个月）
     * @dev 平台管理员调用，USDC 和歌曲代币必须先 approve 给本合约
     * @param songId      歌曲 ID
     * @param usdcAmount  USDC 数量
     * @param tokenAmount 歌曲代币数量
     */
    function seedPool(
        uint256 songId,
        uint256 usdcAmount,
        uint256 tokenAmount
    ) external onlyOwner nonReentrant {
        address pool = songPools[songId];
        require(pool != address(0), "LiquidityBootstrap: pool not created");
        require(!poolInfos[songId].seeded, "LiquidityBootstrap: already seeded");
        require(usdcAmount > 0 && tokenAmount > 0, "LiquidityBootstrap: amounts must be > 0");

        // 转入资产到本合约
        require(
            usdc.transferFrom(msg.sender, address(this), usdcAmount),
            "LiquidityBootstrap: USDC transfer failed"
        );

        IERC20 songToken = IERC20(LiquidityPool(pool).songToken());
        require(
            songToken.transferFrom(msg.sender, address(this), tokenAmount),
            "LiquidityBootstrap: token transfer failed"
        );

        // Approve 给 LiquidityPool
        usdc.approve(pool, usdcAmount);
        songToken.approve(pool, tokenAmount);

        // 添加流动性
        uint256 lpTokens = LiquidityPool(pool).addLiquidity(usdcAmount, tokenAmount);

        // 锁定 LP 代币
        uint256 lockId = ++totalLocks;
        lpLocks[lockId] = LPLock({
            owner: msg.sender,
            pool: pool,
            lpAmount: lpTokens,
            lockedAt: block.timestamp,
            lockDuration: PLATFORM_LOCK_PERIOD,
            released: false,
            lockType: LockType.PLATFORM_SEED
        });

        poolInfos[songId].seeded = true;
        poolInfos[songId].seedUsdcAmount = usdcAmount;
        poolInfos[songId].seedTokenAmount = tokenAmount;

        emit PoolSeeded(songId, pool, usdcAmount, tokenAmount, lpTokens);
        emit LPLocked(lockId, msg.sender, lpTokens, PLATFORM_LOCK_PERIOD, LockType.PLATFORM_SEED);
    }

    /**
     * @notice 艺术家承诺 LP 流动性（锁定 6 个月，享受发行费折扣）
     * @dev 艺术家调用，USDC 和歌曲代币必须先 approve 给本合约
     * @param songId      歌曲 ID
     * @param usdcAmount  USDC 数量
     * @param tokenAmount 歌曲代币数量
     */
    function commitArtistLP(
        uint256 songId,
        uint256 usdcAmount,
        uint256 tokenAmount
    ) external nonReentrant {
        address pool = songPools[songId];
        require(pool != address(0), "LiquidityBootstrap: pool not created");
        require(!artistLPCommitted[songId], "LiquidityBootstrap: artist LP already committed");
        require(usdcAmount > 0 && tokenAmount > 0, "LiquidityBootstrap: amounts must be > 0");

        // 转入资产
        require(
            usdc.transferFrom(msg.sender, address(this), usdcAmount),
            "LiquidityBootstrap: USDC transfer failed"
        );

        IERC20 songToken = IERC20(LiquidityPool(pool).songToken());
        require(
            songToken.transferFrom(msg.sender, address(this), tokenAmount),
            "LiquidityBootstrap: token transfer failed"
        );

        // Approve 给 LiquidityPool
        usdc.approve(pool, usdcAmount);
        songToken.approve(pool, tokenAmount);

        // 添加流动性
        uint256 lpTokens = LiquidityPool(pool).addLiquidity(usdcAmount, tokenAmount);

        // 锁定 LP 代币（6 个月）
        uint256 lockId = ++totalLocks;
        lpLocks[lockId] = LPLock({
            owner: msg.sender,
            pool: pool,
            lpAmount: lpTokens,
            lockedAt: block.timestamp,
            lockDuration: ARTIST_LOCK_PERIOD,
            released: false,
            lockType: LockType.ARTIST_LP
        });

        artistLPCommitted[songId] = true;
        artistDiscountEligible[songId] = true;
        poolInfos[songId].artistLPCommitted = true;

        emit ArtistLPCommitted(songId, msg.sender, usdcAmount, tokenAmount);
        emit LPLocked(lockId, msg.sender, lpTokens, ARTIST_LOCK_PERIOD, LockType.ARTIST_LP);
        emit ArtistDiscountApplied(songId, msg.sender, NORMAL_ISSUANCE_FEE_BPS - DISCOUNTED_ISSUANCE_FEE_BPS);
    }

    /**
     * @notice 锁定期满后解锁 LP 代币
     * @param lockId 锁定记录 ID
     */
    function unlockLP(uint256 lockId) external nonReentrant {
        LPLock storage lock = lpLocks[lockId];
        require(lock.owner == msg.sender, "LiquidityBootstrap: not lock owner");
        require(!lock.released, "LiquidityBootstrap: already released");
        require(
            block.timestamp >= lock.lockedAt + lock.lockDuration,
            "LiquidityBootstrap: lock period not elapsed"
        );

        lock.released = true;

        // 转移 LP 代币给持有者
        IERC20(lock.pool).transfer(msg.sender, lock.lpAmount);

        emit LPUnlocked(lockId, msg.sender, lock.lpAmount);
    }

    // ─── View Functions ────────────────────────────────────────────────────────

    /**
     * @notice 获取歌曲的流动性池地址
     */
    function getPool(uint256 songId) external view returns (address) {
        return songPools[songId];
    }

    /**
     * @notice 获取歌曲的池信息
     */
    function getPoolInfo(uint256 songId) external view returns (PoolInfo memory) {
        return poolInfos[songId];
    }

    /**
     * @notice 获取 LP 锁定信息
     */
    function getLPLock(uint256 lockId) external view returns (LPLock memory) {
        return lpLocks[lockId];
    }

    /**
     * @notice 检查艺术家是否有发行费折扣资格
     */
    function hasArtistDiscount(uint256 songId) external view returns (bool) {
        return artistDiscountEligible[songId];
    }

    /**
     * @notice 获取锁定剩余时间
     */
    function getLockRemainingTime(uint256 lockId) external view returns (uint256) {
        LPLock memory lock = lpLocks[lockId];
        uint256 unlockTime = lock.lockedAt + lock.lockDuration;
        if (block.timestamp >= unlockTime) return 0;
        return unlockTime - block.timestamp;
    }
}
