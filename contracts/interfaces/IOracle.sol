// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title IOracle
 * @notice Interface for Oracle data submission and consensus mechanism
 * @dev Implements multi-node consensus with deviation-based rejection and ZK-ML proof verification
 */
interface IOracle {
    // ─── Structs ───────────────────────────────────────────────────────────────

    struct OracleSubmission {
        address node;           // Oracle node address
        uint256 royaltyAmount;  // Submitted royalty amount in USDC (6 decimals)
        uint256 timestamp;      // Submission timestamp
        bytes zkProof;          // ZK-ML proof bytes (for off-chain verification reference)
        bool accepted;          // Whether this submission was accepted after consensus
    }

    struct RoundData {
        uint256 roundId;
        uint256 month;          // Unix timestamp of month start
        uint256 songId;         // Associated song/token ID
        uint256 medianRoyalty;  // Computed median after consensus
        uint256 submissionCount;
        bool finalized;
    }

    // ─── Events ───────────────────────────────────────────────────────────────

    event OracleNodeRegistered(address indexed node, uint256 stakeAmount);
    event OracleNodeRemoved(address indexed node);
    event RoyaltyDataSubmitted(
        uint256 indexed roundId,
        address indexed node,
        uint256 royaltyAmount,
        bool accepted
    );
    event RoundFinalized(
        uint256 indexed roundId,
        uint256 medianRoyalty,
        uint256 acceptedSubmissions
    );
    event NodeSlashed(address indexed node, uint256 slashedAmount, string reason);
    event CircuitBreakerTriggered(uint256 indexed roundId, string reason);

    // ─── View Functions ────────────────────────────────────────────────────────

    /// @notice Returns whether an address is a whitelisted Oracle node
    function isOracleNode(address node) external view returns (bool);

    /// @notice Returns the minimum number of nodes required for consensus
    function minNodes() external view returns (uint256);

    /// @notice Returns the deviation threshold in basis points (e.g. 2000 = 20%)
    function deviationThresholdBps() external view returns (uint256);

    /// @notice Returns the current round ID for a given song
    function getCurrentRoundId(uint256 songId) external view returns (uint256);

    /// @notice Returns round data for a specific round
    function getRoundData(uint256 roundId) external view returns (RoundData memory);

    // ─── State-Changing Functions ──────────────────────────────────────────────

    /**
     * @notice Submit royalty data for a song (called by whitelisted Oracle nodes)
     * @param songId The song token ID
     * @param royaltyAmount Royalty amount in USDC (6 decimals)
     * @param zkProof ZK-ML proof bytes proving computation integrity
     */
    function submitRoyaltyData(
        uint256 songId,
        uint256 royaltyAmount,
        bytes calldata zkProof
    ) external;

    /**
     * @notice Finalize a round after minimum submissions received
     * @param roundId The round to finalize
     */
    function finalizeRound(uint256 roundId) external;

    /**
     * @notice Register a new Oracle node with stake
     */
    function registerNode() external payable;

    /**
     * @notice Remove an Oracle node (admin only)
     * @param node Address of the node to remove
     */
    function removeNode(address node) external;
}
