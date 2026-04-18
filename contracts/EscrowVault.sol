// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";

/**
 * @title EscrowVault
 * @notice Locks artist security deposits in USDC at song listing time.
 *
 * Business rules:
 *  - Artist deposits 30%-50% of expected annual royalty income at listing
 *  - If artist defaults (no royalty transfer for 2 consecutive months),
 *    the deposit is automatically distributed to token holders
 *  - On clean delisting, the deposit is returned to the artist
 *
 * Called by:
 *  - ListingManager.lockDeposit() at listing
 *  - DelistingManager.distributeToHolders() on confirmed default
 *  - DelistingManager on clean delisting to return deposit
 */
contract EscrowVault is Ownable, ReentrancyGuard {
    // ─── Structs ───────────────────────────────────────────────────────────────

    struct Deposit {
        address artist;          // Artist wallet address
        address musicToken;      // Associated MusicToken contract
        uint256 amount;          // Locked USDC amount (6 decimals)
        uint256 songId;          // Song ID
        bool active;             // Whether deposit is still locked
        uint256 lockedAt;        // Timestamp when deposit was locked
    }

    // ─── Events ───────────────────────────────────────────────────────────────

    event DepositLocked(
        uint256 indexed songId,
        address indexed artist,
        uint256 amount,
        address musicToken
    );
    event DepositDistributed(
        uint256 indexed songId,
        uint256 totalAmount,
        uint256 holderCount
    );
    event DepositReturned(
        uint256 indexed songId,
        address indexed artist,
        uint256 amount
    );
    event AuthorizedCallerUpdated(address indexed caller, bool authorized);

    // ─── State Variables ───────────────────────────────────────────────────────

    /// @notice USDC token contract
    IERC20 public immutable usdc;

    /// @notice Deposits per song ID
    mapping(uint256 => Deposit) public deposits;

    /// @notice Authorized callers (ListingManager, DelistingManager)
    mapping(address => bool) public authorizedCallers;

    // ─── Constructor ───────────────────────────────────────────────────────────

    /**
     * @param _usdc USDC ERC-20 contract address
     */
    constructor(address _usdc) Ownable(msg.sender) {
        require(_usdc != address(0), "EscrowVault: invalid USDC address");
        usdc = IERC20(_usdc);
    }

    // ─── Modifiers ─────────────────────────────────────────────────────────────

    modifier onlyAuthorized() {
        require(
            authorizedCallers[msg.sender] || msg.sender == owner(),
            "EscrowVault: caller not authorized"
        );
        _;
    }

    // ─── External Functions ────────────────────────────────────────────────────

    /**
     * @notice Lock artist security deposit at song listing
     * @dev Called by ListingManager. Artist must have approved this contract to spend USDC.
     * @param songId     Unique song ID
     * @param artist     Artist wallet address
     * @param musicToken Associated MusicToken contract address
     * @param amount     USDC amount to lock (6 decimals)
     */
    function lockDeposit(
        uint256 songId,
        address artist,
        address musicToken,
        uint256 amount
    ) external onlyAuthorized nonReentrant {
        require(artist != address(0), "EscrowVault: invalid artist");
        require(musicToken != address(0), "EscrowVault: invalid music token");
        require(amount > 0, "EscrowVault: amount must be > 0");
        require(!deposits[songId].active, "EscrowVault: deposit already exists");

        require(
            usdc.transferFrom(artist, address(this), amount),
            "EscrowVault: USDC transfer failed"
        );

        deposits[songId] = Deposit({
            artist: artist,
            musicToken: musicToken,
            amount: amount,
            songId: songId,
            active: true,
            lockedAt: block.timestamp
        });

        emit DepositLocked(songId, artist, amount, musicToken);
    }

    /**
     * @notice Distribute deposit to token holders on artist default
     * @dev Called by DelistingManager on confirmed default (2 consecutive missed months).
     *      Distribution is proportional to token holdings.
     * @param songId   Song ID of the defaulted artist
     * @param holders  Array of token holder addresses
     * @param amounts  Array of USDC amounts each holder receives
     */
    function distributeToHolders(
        uint256 songId,
        address[] calldata holders,
        uint256[] calldata amounts
    ) external onlyAuthorized nonReentrant {
        Deposit storage dep = deposits[songId];
        require(dep.active, "EscrowVault: no active deposit");
        require(holders.length == amounts.length, "EscrowVault: array length mismatch");
        require(holders.length > 0, "EscrowVault: no holders");

        dep.active = false;

        uint256 totalDistributed = 0;
        for (uint256 i = 0; i < holders.length; i++) {
            if (amounts[i] > 0 && holders[i] != address(0)) {
                require(
                    usdc.transfer(holders[i], amounts[i]),
                    "EscrowVault: holder transfer failed"
                );
                totalDistributed += amounts[i];
            }
        }

        // Return any dust to platform (rounding errors)
        uint256 remaining = dep.amount - totalDistributed;
        if (remaining > 0) {
            usdc.transfer(owner(), remaining);
        }

        emit DepositDistributed(songId, totalDistributed, holders.length);
    }

    /**
     * @notice Return deposit to artist on clean delisting
     * @dev Called by DelistingManager on voluntary clean delisting
     * @param songId Song ID being delisted
     */
    function returnDeposit(uint256 songId) external onlyAuthorized nonReentrant {
        Deposit storage dep = deposits[songId];
        require(dep.active, "EscrowVault: no active deposit");

        dep.active = false;
        uint256 amount = dep.amount;
        address artist = dep.artist;

        require(
            usdc.transfer(artist, amount),
            "EscrowVault: return transfer failed"
        );

        emit DepositReturned(songId, artist, amount);
    }

    /**
     * @notice Authorize or revoke a caller
     * @param caller  Address to authorize/revoke
     * @param status  True to authorize, false to revoke
     */
    function setAuthorizedCaller(address caller, bool status) external onlyOwner {
        require(caller != address(0), "EscrowVault: invalid caller");
        authorizedCallers[caller] = status;
        emit AuthorizedCallerUpdated(caller, status);
    }

    // ─── View Functions ────────────────────────────────────────────────────────

    /**
     * @notice Returns deposit info for a song
     * @param songId Song ID
     */
    function getDeposit(uint256 songId) external view returns (Deposit memory) {
        return deposits[songId];
    }

    /**
     * @notice Returns whether a deposit is active for a song
     * @param songId Song ID
     */
    function hasActiveDeposit(uint256 songId) external view returns (bool) {
        return deposits[songId].active;
    }
}
