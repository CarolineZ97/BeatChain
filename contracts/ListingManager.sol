// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "./MusicToken.sol";
import "./EscrowVault.sol";
import "./PlatformTreasury.sol";

/**
 * @title ListingManager
 * @notice Manages the full lifecycle of song listings on BeatChain.
 *
 * Lifecycle states:
 *   PENDING  → Song submitted, awaiting approval
 *   ACTIVE   → Token sale live, investors can purchase
 *   DELISTED → Song removed (voluntary or forced)
 *
 * Responsibilities:
 *  - Validates listing eligibility criteria
 *  - Deploys a new MusicToken contract per song
 *  - Calls EscrowVault.lockDeposit() to lock artist security deposit
 *  - Stores song metadata and listing parameters
 *
 * Called by:
 *  - Artist (listSong) to create a new listing
 *  - DelistingManager (setStatus) to update listing status
 *  - Admin (approveListing) to approve pending listings
 */
contract ListingManager is Ownable, ReentrancyGuard {
    // ─── Enums ─────────────────────────────────────────────────────────────────

    enum ListingStatus { PENDING, ACTIVE, DELISTED }

    // ─── Structs ───────────────────────────────────────────────────────────────

    struct SongListing {
        uint256 songId;
        address artist;
        address musicToken;          // Deployed MusicToken contract
        string songName;
        string songURI;              // Metadata URI
        uint256 totalSupply;         // Total token supply (18 decimals)
        uint256 royaltyShareSoldBps; // % of royalty rights sold (max 5000)
        uint256 issuanceFairValue;   // Price per token in USDC (6 decimals)
        uint256 fundingGoal;         // Total USDC to raise (6 decimals)
        uint256 depositAmount;       // Security deposit locked in EscrowVault
        uint256 expectedAnnualRoyalty; // Expected annual royalty income (6 decimals)
        ListingStatus status;
        uint256 listedAt;
        uint256 delistedAt;
    }

    // ─── Events ───────────────────────────────────────────────────────────────

    event SongSubmitted(
        uint256 indexed songId,
        address indexed artist,
        string songName,
        uint256 fundingGoal
    );
    event SongApproved(
        uint256 indexed songId,
        address indexed musicToken,
        uint256 depositAmount
    );
    event SongDelisted(
        uint256 indexed songId,
        address indexed artist,
        string reason
    );
    event StatusUpdated(uint256 indexed songId, ListingStatus oldStatus, ListingStatus newStatus);
    event ArtistLPDiscountApplied(uint256 indexed songId, address indexed artist);

    // ─── State Variables ───────────────────────────────────────────────────────

    /// @notice USDC token address
    address public immutable usdcToken;

    /// @notice EscrowVault contract
    EscrowVault public immutable escrowVault;

    /// @notice PlatformTreasury contract
    address public immutable platformTreasury;

    /// @notice Authorized callers (DelistingManager)
    mapping(address => bool) public authorizedCallers;

    /// @notice Song listings by ID
    mapping(uint256 => SongListing) public listings;

    /// @notice Songs listed by artist
    mapping(address => uint256[]) public artistSongs;

    /// @notice Total songs listed
    uint256 public totalSongs;

    /// @notice Artist LP discount eligibility (songId => eligible)
    mapping(uint256 => bool) public artistLPDiscountEligible;

    /// @notice LiquidityBootstrap contract address (set after deployment)
    address public liquidityBootstrap;

    /// @notice Normal issuance fee in basis points (3%)
    uint256 public constant NORMAL_ISSUANCE_FEE_BPS = 300;

    /// @notice Discounted issuance fee in basis points (2%)
    uint256 public constant DISCOUNTED_ISSUANCE_FEE_BPS = 200;

    /// @notice Minimum deposit ratio in basis points (30% of expected annual royalty)
    uint256 public constant MIN_DEPOSIT_RATIO_BPS = 3000;

    /// @notice Maximum deposit ratio in basis points (50% of expected annual royalty)
    uint256 public constant MAX_DEPOSIT_RATIO_BPS = 5000;

    /// @notice Maximum royalty share that can be sold (50%)
    uint256 public constant MAX_ROYALTY_SHARE_BPS = 5000;

    /// @notice Basis points denominator
    uint256 public constant BPS_DENOMINATOR = 10000;

    // ─── Constructor ───────────────────────────────────────────────────────────

    /**
     * @param _usdcToken       USDC ERC-20 contract address
     * @param _escrowVault     EscrowVault contract address
     * @param _platformTreasury PlatformTreasury contract address
     */
    constructor(
        address _usdcToken,
        address _escrowVault,
        address _platformTreasury
    ) Ownable(msg.sender) {
        require(_usdcToken != address(0), "ListingManager: invalid USDC");
        require(_escrowVault != address(0), "ListingManager: invalid escrow");
        require(_platformTreasury != address(0), "ListingManager: invalid treasury");

        usdcToken = _usdcToken;
        escrowVault = EscrowVault(_escrowVault);
        platformTreasury = _platformTreasury;
    }

    // ─── Modifiers ─────────────────────────────────────────────────────────────

    modifier onlyAuthorized() {
        require(
            authorizedCallers[msg.sender] || msg.sender == owner(),
            "ListingManager: caller not authorized"
        );
        _;
    }

    // ─── External Functions ────────────────────────────────────────────────────

    /**
     * @notice Submit a new song for listing (Step 1: artist submits)
     * @dev Creates a PENDING listing. Admin must approve before token sale starts.
     * @param songName             Song display name
     * @param songSymbol           Token symbol (e.g. "SONG1")
     * @param songURI              Metadata URI
     * @param totalSupply          Total token supply (18 decimals)
     * @param royaltyShareSoldBps  % of royalty rights to sell (max 5000 = 50%)
     * @param issuanceFairValue    Price per token in USDC (6 decimals)
     * @param expectedAnnualRoyalty Expected annual royalty income in USDC (6 decimals)
     * @param depositAmount        Security deposit amount in USDC (must be 30-50% of annual royalty)
     */
    function submitListing(
        string calldata songName,
        string calldata songSymbol,
        string calldata songURI,
        uint256 totalSupply,
        uint256 royaltyShareSoldBps,
        uint256 issuanceFairValue,
        uint256 expectedAnnualRoyalty,
        uint256 depositAmount
    ) external nonReentrant returns (uint256 songId) {
        require(bytes(songName).length > 0, "ListingManager: empty song name");
        require(totalSupply > 0, "ListingManager: supply must be > 0");
        require(royaltyShareSoldBps > 0, "ListingManager: royalty share must be > 0");
        require(royaltyShareSoldBps <= MAX_ROYALTY_SHARE_BPS, "ListingManager: exceeds max royalty share");
        require(issuanceFairValue > 0, "ListingManager: fair value must be > 0");
        require(expectedAnnualRoyalty > 0, "ListingManager: expected royalty must be > 0");

        // Validate deposit is within 30%-50% of expected annual royalty
        uint256 minDeposit = (expectedAnnualRoyalty * MIN_DEPOSIT_RATIO_BPS) / BPS_DENOMINATOR;
        uint256 maxDeposit = (expectedAnnualRoyalty * MAX_DEPOSIT_RATIO_BPS) / BPS_DENOMINATOR;
        require(depositAmount >= minDeposit, "ListingManager: deposit below minimum");
        require(depositAmount <= maxDeposit, "ListingManager: deposit above maximum");

        songId = ++totalSongs;

        // Calculate funding goal: totalSupply * issuanceFairValue / 1e18
        uint256 fundingGoal = (totalSupply * issuanceFairValue) / 1e18;

        listings[songId] = SongListing({
            songId: songId,
            artist: msg.sender,
            musicToken: address(0), // Deployed on approval
            songName: songName,
            songURI: songURI,
            totalSupply: totalSupply,
            royaltyShareSoldBps: royaltyShareSoldBps,
            issuanceFairValue: issuanceFairValue,
            fundingGoal: fundingGoal,
            depositAmount: depositAmount,
            expectedAnnualRoyalty: expectedAnnualRoyalty,
            status: ListingStatus.PENDING,
            listedAt: block.timestamp,
            delistedAt: 0
        });

        artistSongs[msg.sender].push(songId);

        emit SongSubmitted(songId, msg.sender, songName, fundingGoal);
    }

    /**
     * @notice Approve a pending listing and deploy MusicToken (Step 2: admin approves)
     * @dev Deploys MusicToken, locks artist deposit in EscrowVault, sets status to ACTIVE.
     *      Artist must have approved EscrowVault to spend depositAmount USDC before calling.
     * @param songId Song ID to approve
     * @param songSymbol Token symbol for the MusicToken
     */
    function approveListing(uint256 songId, string calldata songSymbol) external onlyOwner nonReentrant {
        SongListing storage listing = listings[songId];
        require(listing.songId == songId, "ListingManager: song not found");
        require(listing.status == ListingStatus.PENDING, "ListingManager: not pending");

        // Deploy MusicToken contract
        MusicToken musicToken = new MusicToken(
            listing.songName,
            songSymbol,
            listing.totalSupply,
            listing.artist,
            listing.royaltyShareSoldBps,
            listing.issuanceFairValue,
            listing.songURI,
            usdcToken,
            platformTreasury,
            songId,
            listing.fundingGoal
        );

        listing.musicToken = address(musicToken);
        listing.status = ListingStatus.ACTIVE;

        // Lock artist security deposit in EscrowVault
        // Artist must have pre-approved EscrowVault to spend USDC
        escrowVault.lockDeposit(
            songId,
            listing.artist,
            address(musicToken),
            listing.depositAmount
        );

        emit SongApproved(songId, address(musicToken), listing.depositAmount);
        emit StatusUpdated(songId, ListingStatus.PENDING, ListingStatus.ACTIVE);
    }

    /**
     * @notice Update listing status (called by DelistingManager)
     * @param songId    Song ID
     * @param newStatus New listing status
     */
    function setStatus(uint256 songId, ListingStatus newStatus) external onlyAuthorized {
        SongListing storage listing = listings[songId];
        require(listing.songId == songId, "ListingManager: song not found");

        ListingStatus oldStatus = listing.status;
        listing.status = newStatus;

        if (newStatus == ListingStatus.DELISTED) {
            listing.delistedAt = block.timestamp;
            emit SongDelisted(songId, listing.artist, "Status updated by authorized caller");
        }

        emit StatusUpdated(songId, oldStatus, newStatus);
    }

    /**
     * @notice Set LiquidityBootstrap contract address
     * @param _liquidityBootstrap LiquidityBootstrap contract address
     */
    function setLiquidityBootstrap(address _liquidityBootstrap) external onlyOwner {
        require(_liquidityBootstrap != address(0), "ListingManager: invalid bootstrap");
        liquidityBootstrap = _liquidityBootstrap;
    }

    /**
     * @notice Mark a song as eligible for artist LP discount
     * @dev Called by LiquidityBootstrap when artist commits LP
     * @param songId Song ID
     */
    function setArtistLPDiscount(uint256 songId, bool eligible) external {
        require(
            msg.sender == liquidityBootstrap || msg.sender == owner(),
            "ListingManager: caller not authorized"
        );
        artistLPDiscountEligible[songId] = eligible;
        if (eligible) {
            emit ArtistLPDiscountApplied(songId, listings[songId].artist);
        }
    }

    /**
     * @notice Get the effective issuance fee for a song
     * @param songId Song ID
     * @return feeBps Issuance fee in basis points
     */
    function getEffectiveIssuanceFeeBps(uint256 songId) external view returns (uint256 feeBps) {
        if (artistLPDiscountEligible[songId]) {
            return DISCOUNTED_ISSUANCE_FEE_BPS;
        }
        return NORMAL_ISSUANCE_FEE_BPS;
    }

    /**
     * @notice Set authorized caller (DelistingManager)
     */
    function setAuthorizedCaller(address caller, bool status) external onlyOwner {
        require(caller != address(0), "ListingManager: invalid caller");
        authorizedCallers[caller] = status;
    }

    // ─── View Functions ────────────────────────────────────────────────────────

    function getListing(uint256 songId) external view returns (SongListing memory) {
        return listings[songId];
    }

    function getArtistSongs(address artist) external view returns (uint256[] memory) {
        return artistSongs[artist];
    }

    function getMusicToken(uint256 songId) external view returns (address) {
        return listings[songId].musicToken;
    }

    function getListingStatus(uint256 songId) external view returns (ListingStatus) {
        return listings[songId].status;
    }
}