// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title IRoyaltyDistributor
 * @notice Interface for the royalty distribution contract
 * @dev Uses pull pattern — holders claim their USDC, contract does not push
 */
interface IRoyaltyDistributor {
    // ─── Structs ───────────────────────────────────────────────────────────────

    struct DistributionRound {
        uint256 roundId;
        uint256 songId;
        uint256 totalUsdcReceived;   // Total USDC received from SPV trust
        uint256 platformFeeDeducted; // 1% platform fee
        uint256 netDistributable;    // Amount available to token holders
        uint256 timestamp;
        bool distributed;
    }

    // ─── Events ───────────────────────────────────────────────────────────────

    event RoyaltyReceived(
        uint256 indexed roundId,
        uint256 indexed songId,
        uint256 totalAmount,
        uint256 platformFee,
        uint256 netAmount
    );
    event RoyaltyClaimed(
        address indexed holder,
        uint256 indexed songId,
        uint256 amount
    );
    event PlatformFeeTransferred(uint256 amount, address treasury);

    // ─── View Functions ────────────────────────────────────────────────────────

    /// @notice Returns the claimable USDC balance for a holder for a specific song
    function claimableBalance(address holder, uint256 songId) external view returns (uint256);

    /// @notice Returns the total claimable USDC balance for a holder across all songs
    function totalClaimableBalance(address holder) external view returns (uint256);

    /// @notice Returns distribution round data
    function getDistributionRound(uint256 roundId) external view returns (DistributionRound memory);

    /// @notice Returns the platform treasury address
    function platformTreasury() external view returns (address);

    /// @notice Returns the platform distribution fee in basis points (100 = 1%)
    function platformFeeBps() external view returns (uint256);

    // ─── State-Changing Functions ──────────────────────────────────────────────

    /**
     * @notice Receive royalty USDC from SPV trust and record claimable balances
     * @dev Called by OracleConsumer after data validation. Deducts 1% platform fee.
     * @param songId The song token ID
     * @param usdcAmount Total USDC amount received
     */
    function receiveRoyalty(uint256 songId, uint256 usdcAmount) external;

    /**
     * @notice Claim accumulated USDC royalties for a specific song
     * @param songId The song token ID to claim royalties for
     */
    function claimRoyalty(uint256 songId) external;

    /**
     * @notice Claim all accumulated USDC royalties across all songs
     */
    function claimAllRoyalties() external;
}
