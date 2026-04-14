// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title PriceFeed
 * @notice Stores and updates the DCF (Discounted Cash Flow) fair value per token,
 *         updated monthly by the Oracle network.
 *
 * Business rules:
 *  - Fair value is updated monthly by OracleConsumer after data validation
 *  - If fair value change > 25% month-over-month, a manual review flag is triggered
 *  - DelistingManager reads fair value to monitor delisting conditions
 *  - Front-end reads fair value for display purposes
 *
 * Called by:
 *  - OracleConsumer.updateFairValue() after data passes validation
 * Read by:
 *  - DelistingManager.getFairValue()
 *  - Front-end
 */
contract PriceFeed is Ownable {
    // ─── Constants ─────────────────────────────────────────────────────────────

    /// @notice Threshold for manual review flag (25% change in basis points)
    uint256 public constant MANUAL_REVIEW_THRESHOLD_BPS = 2500;

    /// @notice Basis points denominator
    uint256 public constant BPS_DENOMINATOR = 10000;

    // ─── Structs ───────────────────────────────────────────────────────────────

    struct FairValueRecord {
        uint256 fairValue;       // DCF fair value per token in USDC (6 decimals)
        uint256 timestamp;       // When this value was recorded
        uint256 monthlyRoyalty;  // Monthly royalty income used to compute this value
        bool manualReviewFlag;   // True if change exceeded 25% threshold
    }

    // ─── Events ───────────────────────────────────────────────────────────────

    event FairValueUpdated(
        uint256 indexed songId,
        uint256 oldFairValue,
        uint256 newFairValue,
        uint256 timestamp,
        bool manualReviewFlag
    );
    event ManualReviewTriggered(
        uint256 indexed songId,
        uint256 oldFairValue,
        uint256 newFairValue,
        uint256 changePercent
    );
    event AuthorizedUpdaterSet(address indexed updater, bool authorized);

    // ─── State Variables ───────────────────────────────────────────────────────

    /// @notice Current fair value per song (songId => FairValueRecord)
    mapping(uint256 => FairValueRecord) public currentFairValues;

    /// @notice Historical fair value records (songId => month index => record)
    mapping(uint256 => mapping(uint256 => FairValueRecord)) public historicalFairValues;

    /// @notice Number of historical records per song
    mapping(uint256 => uint256) public recordCount;

    /// @notice Authorized updaters (OracleConsumer)
    mapping(address => bool) public authorizedUpdaters;

    // ─── Constructor ───────────────────────────────────────────────────────────

    constructor() Ownable(msg.sender) {}

    // ─── Modifiers ─────────────────────────────────────────────────────────────

    modifier onlyAuthorized() {
        require(
            authorizedUpdaters[msg.sender] || msg.sender == owner(),
            "PriceFeed: caller not authorized"
        );
        _;
    }

    // ─── External Functions ────────────────────────────────────────────────────

    /**
     * @notice Update the fair value for a song
     * @dev Called by OracleConsumer after royalty data passes validation.
     *      Triggers manual review flag if change > 25%.
     * @param songId         Song ID
     * @param newFairValue   New DCF fair value per token in USDC (6 decimals)
     * @param monthlyRoyalty Monthly royalty income used to compute this value
     */
    function updateFairValue(
        uint256 songId,
        uint256 newFairValue,
        uint256 monthlyRoyalty
    ) external onlyAuthorized {
        require(newFairValue > 0, "PriceFeed: fair value must be > 0");

        FairValueRecord storage current = currentFairValues[songId];
        uint256 oldFairValue = current.fairValue;
        bool manualReviewFlag = false;

        // Check if change exceeds 25% threshold
        if (oldFairValue > 0) {
            uint256 changeBps;
            if (newFairValue > oldFairValue) {
                changeBps = ((newFairValue - oldFairValue) * BPS_DENOMINATOR) / oldFairValue;
            } else {
                changeBps = ((oldFairValue - newFairValue) * BPS_DENOMINATOR) / oldFairValue;
            }

            if (changeBps > MANUAL_REVIEW_THRESHOLD_BPS) {
                manualReviewFlag = true;
                emit ManualReviewTriggered(songId, oldFairValue, newFairValue, changeBps);
            }
        }

        // Store historical record
        uint256 idx = recordCount[songId];
        historicalFairValues[songId][idx] = FairValueRecord({
            fairValue: newFairValue,
            timestamp: block.timestamp,
            monthlyRoyalty: monthlyRoyalty,
            manualReviewFlag: manualReviewFlag
        });
        recordCount[songId] = idx + 1;

        // Update current record
        currentFairValues[songId] = FairValueRecord({
            fairValue: newFairValue,
            timestamp: block.timestamp,
            monthlyRoyalty: monthlyRoyalty,
            manualReviewFlag: manualReviewFlag
        });

        emit FairValueUpdated(songId, oldFairValue, newFairValue, block.timestamp, manualReviewFlag);
    }

    /**
     * @notice Set authorized updater (OracleConsumer)
     * @param updater   Address to authorize/revoke
     * @param authorized True to authorize, false to revoke
     */
    function setAuthorizedUpdater(address updater, bool authorized) external onlyOwner {
        require(updater != address(0), "PriceFeed: invalid updater");
        authorizedUpdaters[updater] = authorized;
        emit AuthorizedUpdaterSet(updater, authorized);
    }

    // ─── View Functions ────────────────────────────────────────────────────────

    /**
     * @notice Get the current fair value for a song
     * @param songId Song ID
     * @return fairValue Current DCF fair value per token (USDC, 6 decimals)
     */
    function getFairValue(uint256 songId) external view returns (uint256 fairValue) {
        return currentFairValues[songId].fairValue;
    }

    /**
     * @notice Get the full current fair value record for a song
     * @param songId Song ID
     */
    function getFairValueRecord(uint256 songId) external view returns (FairValueRecord memory) {
        return currentFairValues[songId];
    }

    /**
     * @notice Get a historical fair value record
     * @param songId Song ID
     * @param index  Historical record index (0 = oldest)
     */
    function getHistoricalRecord(
        uint256 songId,
        uint256 index
    ) external view returns (FairValueRecord memory) {
        require(index < recordCount[songId], "PriceFeed: index out of bounds");
        return historicalFairValues[songId][index];
    }

    /**
     * @notice Get the last N fair value records for a song
     * @param songId Song ID
     * @param n      Number of records to retrieve
     */
    function getLastNRecords(
        uint256 songId,
        uint256 n
    ) external view returns (FairValueRecord[] memory records) {
        uint256 total = recordCount[songId];
        uint256 count = n > total ? total : n;
        records = new FairValueRecord[](count);

        for (uint256 i = 0; i < count; i++) {
            records[i] = historicalFairValues[songId][total - count + i];
        }
    }
}
