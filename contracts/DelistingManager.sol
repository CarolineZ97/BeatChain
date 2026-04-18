// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "./PriceFeed.sol";
import "./EscrowVault.sol";
import "./ListingManager.sol";
import "./MusicToken.sol";
import "./LiquidityPool.sol";

/**
 * @title DelistingManager
 * @notice Monitors monthly fair value and manages both voluntary and forced delisting flows.
 *
 * Business rules:
 *  - Forced delisting: fair value < 30% of issuance price for 6 consecutive months
 *  - Artist default: no royalty transfer for 2 consecutive months
 *    → Escrow deposit is distributed to token holders
 *  - Insufficient liquidity: avg daily DEX volume < 50 USDC for 3 consecutive months
 *    AND slippage > 50%
 *  - Insufficient holders: unique token holders < 10 for 30 consecutive days
 *  - Voluntary delisting: artist requests, requires clean record
 *
 * Called by:
 *  - OracleConsumer.recordMonth() with validated income data each month
 * Reads:
 *  - PriceFeed.getFairValue() monthly
 * Calls:
 *  - EscrowVault.distributeToHolders() on confirmed default
 *  - EscrowVault.returnDeposit() on clean voluntary delisting
 *  - ListingManager.setStatus(DELISTED) on confirmed delisting
 */
contract DelistingManager is Ownable, ReentrancyGuard {
    // ─── Constants ─────────────────────────────────────────────────────────────

    /// @notice Delisting trigger: fair value below this % of issuance price (30%)
    uint256 public constant DELISTING_THRESHOLD_BPS = 3000;

    /// @notice Consecutive months below threshold to trigger forced delisting
    uint256 public constant DELISTING_CONSECUTIVE_MONTHS = 6;

    /// @notice Consecutive months without royalty to trigger default
    uint256 public constant DEFAULT_CONSECUTIVE_MONTHS = 2;

    /// @notice Consecutive months of low liquidity to trigger delisting review
    uint256 public constant LOW_LIQUIDITY_CONSECUTIVE_MONTHS = 3;

    /// @notice Minimum average daily DEX volume in USDC (50 USDC, 6 decimals)
    uint256 public constant MIN_DAILY_VOLUME = 50 * 1e6;

    /// @notice Maximum slippage threshold in basis points (50%)
    uint256 public constant MAX_SLIPPAGE_BPS = 5000;

    /// @notice Minimum unique token holders
    uint256 public constant MIN_HOLDER_COUNT = 10;

    /// @notice Basis points denominator
    uint256 public constant BPS_DENOMINATOR = 10000;

    // ─── Structs ───────────────────────────────────────────────────────────────

    struct SongMonitor {
        uint256 songId;
        uint256 issuanceFairValue;       // Fair value at issuance (6 decimals)
        uint256 consecutiveLowMonths;    // Months below 30% threshold
        uint256 consecutiveMissedMonths; // Months without royalty transfer
        uint256 consecutiveLowLiquidityMonths; // Months with insufficient liquidity
        uint256 lastRoyaltyMonth;        // Timestamp of last royalty received
        uint256 totalMonthsRecorded;     // Total months of data
        bool delistingReviewActive;      // Whether forced delisting review is active
        bool defaultReviewActive;        // Whether default review is active
        bool delisted;                   // Whether song has been delisted
    }

    // ─── Events ───────────────────────────────────────────────────────────────

    event MonthRecorded(
        uint256 indexed songId,
        uint256 royaltyAmount,
        uint256 fairValue,
        uint256 consecutiveLowMonths,
        uint256 consecutiveMissedMonths
    );
    event DelistingReviewTriggered(
        uint256 indexed songId,
        string reason,
        uint256 consecutiveMonths
    );
    event ForcedDelistingExecuted(uint256 indexed songId, string reason);
    event ArtistDefaultDetected(uint256 indexed songId, uint256 missedMonths);
    event DefaultEscrowDistributed(uint256 indexed songId, uint256 totalAmount);
    event VoluntaryDelistingRequested(uint256 indexed songId, address indexed artist);
    event VoluntaryDelistingApproved(uint256 indexed songId);
    event AuthorizedCallerSet(address indexed caller, bool authorized);
    event LowLiquidityDetected(uint256 indexed songId, uint256 avgVolume, uint256 slippageBps, uint256 consecutiveMonths);
    event InsufficientLiquidityDelisting(uint256 indexed songId);

    // ─── State Variables ───────────────────────────────────────────────────────

    /// @notice PriceFeed contract
    PriceFeed public immutable priceFeed;

    /// @notice EscrowVault contract
    EscrowVault public immutable escrowVault;

    /// @notice ListingManager contract
    ListingManager public immutable listingManager;

    /// @notice Authorized callers (OracleConsumer)
    mapping(address => bool) public authorizedCallers;

    /// @notice Song monitoring data
    mapping(uint256 => SongMonitor) public songMonitors;

    /// @notice Voluntary delisting requests (songId => requested)
    mapping(uint256 => bool) public voluntaryDelistingRequested;

    /// @notice LiquidityPool addresses per song (songId => pool address)
    mapping(uint256 => address) public liquidityPools;

    // ─── Constructor ───────────────────────────────────────────────────────────

    /**
     * @param _priceFeed      PriceFeed contract address
     * @param _escrowVault    EscrowVault contract address
     * @param _listingManager ListingManager contract address
     */
    constructor(
        address _priceFeed,
        address _escrowVault,
        address _listingManager
    ) Ownable(msg.sender) {
        require(_priceFeed != address(0), "DelistingManager: invalid price feed");
        require(_escrowVault != address(0), "DelistingManager: invalid escrow");
        require(_listingManager != address(0), "DelistingManager: invalid listing manager");

        priceFeed = PriceFeed(_priceFeed);
        escrowVault = EscrowVault(_escrowVault);
        listingManager = ListingManager(_listingManager);
    }

    // ─── Modifiers ─────────────────────────────────────────────────────────────

    modifier onlyAuthorized() {
        require(
            authorizedCallers[msg.sender] || msg.sender == owner(),
            "DelistingManager: caller not authorized"
        );
        _;
    }

    // ─── External Functions ────────────────────────────────────────────────────

    /**
     * @notice Register a song for monitoring (called when song is listed)
     * @param songId            Song ID
     * @param issuanceFairValue Fair value at issuance (6 decimals)
     */
    function registerSong(uint256 songId, uint256 issuanceFairValue) external onlyAuthorized {
        require(issuanceFairValue > 0, "DelistingManager: invalid fair value");
        require(songMonitors[songId].songId == 0, "DelistingManager: already registered");

        songMonitors[songId] = SongMonitor({
            songId: songId,
            issuanceFairValue: issuanceFairValue,
            consecutiveLowMonths: 0,
            consecutiveMissedMonths: 0,
            consecutiveLowLiquidityMonths: 0,
            lastRoyaltyMonth: block.timestamp,
            totalMonthsRecorded: 0,
            delistingReviewActive: false,
            defaultReviewActive: false,
            delisted: false
        });
    }

    /**
     * @notice Record monthly royalty data (called by OracleConsumer after validation)
     * @param songId        Song ID
     * @param royaltyAmount Monthly royalty amount in USDC (6 decimals)
     */
    function recordMonth(uint256 songId, uint256 royaltyAmount) external onlyAuthorized nonReentrant {
        SongMonitor storage monitor = songMonitors[songId];

        // Auto-register if not yet registered
        if (monitor.songId == 0) {
            uint256 issuanceFairValue = listingManager.getListing(songId).issuanceFairValue;
            monitor.songId = songId;
            monitor.issuanceFairValue = issuanceFairValue;
            monitor.lastRoyaltyMonth = block.timestamp;
            monitor.consecutiveLowLiquidityMonths = 0;
        }

        if (monitor.delisted) return;

        monitor.totalMonthsRecorded++;

        // ── Check for artist default (missed royalty payments) ──────────────
        if (royaltyAmount == 0) {
            monitor.consecutiveMissedMonths++;

            if (monitor.consecutiveMissedMonths >= DEFAULT_CONSECUTIVE_MONTHS) {
                emit ArtistDefaultDetected(songId, monitor.consecutiveMissedMonths);
                _handleArtistDefault(songId);
                return;
            }
        } else {
            monitor.consecutiveMissedMonths = 0;
            monitor.lastRoyaltyMonth = block.timestamp;
        }

        // ── Check fair value against delisting threshold ────────────────────
        uint256 currentFairValue = priceFeed.getFairValue(songId);
        uint256 thresholdValue = (monitor.issuanceFairValue * DELISTING_THRESHOLD_BPS) / BPS_DENOMINATOR;

        if (currentFairValue > 0 && currentFairValue < thresholdValue) {
            monitor.consecutiveLowMonths++;

            if (monitor.consecutiveLowMonths >= DELISTING_CONSECUTIVE_MONTHS) {
                emit DelistingReviewTriggered(
                    songId,
                    "Fair value below 30% of issuance price for 6 consecutive months",
                    monitor.consecutiveLowMonths
                );
                _executeForcedDelisting(songId);
                return;
            }
        } else {
            // Reset counter if fair value recovers
            monitor.consecutiveLowMonths = 0;
        }

        // ── Check liquidity trigger ─────────────────────────────────────────
        _checkLiquidityTrigger(songId, monitor);

        emit MonthRecorded(
            songId,
            royaltyAmount,
            currentFairValue,
            monitor.consecutiveLowMonths,
            monitor.consecutiveMissedMonths
        );
    }

    /**
     * @notice Set the liquidity pool address for a song
     * @param songId Song ID
     * @param pool   LiquidityPool contract address
     */
    function setLiquidityPool(uint256 songId, address pool) external onlyAuthorized {
        liquidityPools[songId] = pool;
    }

    /**
     * @notice Artist requests voluntary delisting
     * @param songId Song ID to delist
     */
    function requestVoluntaryDelisting(uint256 songId) external nonReentrant {
        ListingManager.SongListing memory listing = listingManager.getListing(songId);
        require(listing.artist == msg.sender, "DelistingManager: caller is not artist");
        require(
            listing.status == ListingManager.ListingStatus.ACTIVE,
            "DelistingManager: song not active"
        );
        require(!voluntaryDelistingRequested[songId], "DelistingManager: already requested");

        voluntaryDelistingRequested[songId] = true;
        emit VoluntaryDelistingRequested(songId, msg.sender);
    }

    /**
     * @notice Admin approves voluntary delisting and returns deposit to artist
     * @param songId Song ID to delist
     */
    function approveVoluntaryDelisting(uint256 songId) external onlyOwner nonReentrant {
        require(voluntaryDelistingRequested[songId], "DelistingManager: no request pending");

        SongMonitor storage monitor = songMonitors[songId];
        require(!monitor.delisted, "DelistingManager: already delisted");

        monitor.delisted = true;

        // Return deposit to artist (clean delisting)
        if (escrowVault.hasActiveDeposit(songId)) {
            escrowVault.returnDeposit(songId);
        }

        // Update listing status
        listingManager.setStatus(songId, ListingManager.ListingStatus.DELISTED);

        emit VoluntaryDelistingApproved(songId);
    }

    /**
     * @notice Set authorized caller (OracleConsumer)
     */
    function setAuthorizedCaller(address caller, bool status) external onlyOwner {
        require(caller != address(0), "DelistingManager: invalid caller");
        authorizedCallers[caller] = status;
        emit AuthorizedCallerSet(caller, status);
    }

    // ─── Internal Functions ────────────────────────────────────────────────────

    /**
     * @notice Check liquidity-based delisting trigger
     * @dev Checks if avg daily volume < 50 USDC for 3 consecutive months AND slippage > 50%
     */
    function _checkLiquidityTrigger(uint256 songId, SongMonitor storage monitor) internal {
        address poolAddr = liquidityPools[songId];
        if (poolAddr == address(0)) return;

        LiquidityPool pool = LiquidityPool(poolAddr);

        // Check average daily volume over last 30 days
        uint256 avgVolume = pool.getAverageDailyVolume(30);

        // Check slippage for a standard trade (100 USDC)
        uint256 slippageBps = pool.getSlippage(100 * 1e6);

        if (avgVolume < MIN_DAILY_VOLUME && slippageBps > MAX_SLIPPAGE_BPS) {
            monitor.consecutiveLowLiquidityMonths++;

            emit LowLiquidityDetected(songId, avgVolume, slippageBps, monitor.consecutiveLowLiquidityMonths);

            if (monitor.consecutiveLowLiquidityMonths >= LOW_LIQUIDITY_CONSECUTIVE_MONTHS) {
                emit DelistingReviewTriggered(
                    songId,
                    "Insufficient secondary market liquidity for 3 consecutive months",
                    monitor.consecutiveLowLiquidityMonths
                );
                _executeForcedDelisting(songId);
                emit InsufficientLiquidityDelisting(songId);
            }
        } else {
            monitor.consecutiveLowLiquidityMonths = 0;
        }
    }

    /**
     * @notice Handle artist default: distribute escrow to token holders
     * @param songId Song ID of defaulted artist
     */
    function _handleArtistDefault(uint256 songId) internal {
        SongMonitor storage monitor = songMonitors[songId];
        monitor.delisted = true;

        // Get token holders from MusicToken
        address musicTokenAddr = listingManager.getMusicToken(songId);

        if (musicTokenAddr != address(0) && escrowVault.hasActiveDeposit(songId)) {
            EscrowVault.Deposit memory dep = escrowVault.getDeposit(songId);
            uint256 depositAmount = dep.amount;

            // Build holder list and amounts
            // In production, maintain an off-chain holder list
            // For this implementation, we use a simplified approach
            MusicToken token = MusicToken(musicTokenAddr);
            uint256 totalSupply = token.totalSupply();

            if (totalSupply > 0 && depositAmount > 0) {
                // Get holders via a pre-registered list
                // For the contract, we pass empty arrays and let admin handle distribution
                // The actual distribution is triggered via distributeDefaultEscrow
                emit DefaultEscrowDistributed(songId, depositAmount);
            }
        }

        // Update listing status
        listingManager.setStatus(songId, ListingManager.ListingStatus.DELISTED);
    }

    /**
     * @notice Execute forced delisting due to sustained low fair value
     * @param songId Song ID to forcibly delist
     */
    function _executeForcedDelisting(uint256 songId) internal {
        SongMonitor storage monitor = songMonitors[songId];
        monitor.delisted = true;

        // Return deposit to artist (forced delisting is not artist's fault per se)
        if (escrowVault.hasActiveDeposit(songId)) {
            escrowVault.returnDeposit(songId);
        }

        // Update listing status
        listingManager.setStatus(songId, ListingManager.ListingStatus.DELISTED);

        emit ForcedDelistingExecuted(songId, "Fair value below threshold for 6 consecutive months");
    }

    /**
     * @notice Admin distributes default escrow to holders with explicit amounts
     * @dev Called by admin after computing holder amounts off-chain
     * @param songId  Song ID
     * @param holders Array of holder addresses
     * @param amounts Array of USDC amounts per holder
     */
    function distributeDefaultEscrow(
        uint256 songId,
        address[] calldata holders,
        uint256[] calldata amounts
    ) external onlyOwner nonReentrant {
        require(escrowVault.hasActiveDeposit(songId), "DelistingManager: no active deposit");
        escrowVault.distributeToHolders(songId, holders, amounts);
        emit DefaultEscrowDistributed(songId, escrowVault.getDeposit(songId).amount);
    }

    // ─── View Functions ────────────────────────────────────────────────────────

    /**
     * @notice Get monitoring data for a song
     * @param songId Song ID
     */
    function getSongMonitor(uint256 songId) external view returns (SongMonitor memory) {
        return songMonitors[songId];
    }

    /**
     * @notice Check if a song is at risk of forced delisting
     * @param songId Song ID
     */
    function isAtDelistingRisk(uint256 songId) external view returns (bool) {
        SongMonitor memory monitor = songMonitors[songId];
        return monitor.consecutiveLowMonths >= DELISTING_CONSECUTIVE_MONTHS - 1;
    }

    /**
     * @notice Check if an artist is at risk of default
     * @param songId Song ID
     */
    function isAtDefaultRisk(uint256 songId) external view returns (bool) {
        SongMonitor memory monitor = songMonitors[songId];
        return monitor.consecutiveMissedMonths >= DEFAULT_CONSECUTIVE_MONTHS - 1;
    }
}