// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "./interfaces/IOracle.sol";
import "./RoyaltyDistributor.sol";
import "./PriceFeed.sol";
import "./DelistingManager.sol";
import "./MusicToken.sol";
import "./LiquidityPool.sol";

/**
 * @title OracleConsumer
 * @notice Multi-node Oracle that accepts royalty data submissions from whitelisted nodes,
 *         computes the median, rejects outliers (>20% deviation), and triggers downstream
 *         contracts after consensus is reached.
 *
 * Architecture (ZK-ML aware):
 *  - Each Oracle node submits royalty data + ZK proof + wash streaming risk score
 *  - Contract computes median of all accepted submissions
 *  - Submissions deviating >20% from median are rejected and node is slashed
 *  - Wash streaming risk score triggers circuit breaker if > 70 (Red flag)
 *  - After consensus (min 3 nodes), triggers:
 *      → PriceFeed.updateFairValue()
 *      → RoyaltyDistributor.receiveRoyalty()
 *      → DelistingManager.recordMonth()
 *
 * Business rules:
 *  - Minimum 3 Oracle nodes required for consensus
 *  - Deviation threshold: 20% (submissions beyond this are rejected)
 *  - Circuit breaker: if wash streaming risk > 70, pause distribution for 72 hours
 *  - Yellow flag (40-70): data submitted with anomaly flag, distribution proceeds
 *  - Green (0-40): normal processing
 *
 * Called by:
 *  - Whitelisted Oracle nodes (submitRoyaltyData)
 */
contract OracleConsumer is Ownable, ReentrancyGuard, IOracle {
    // ─── Constants ─────────────────────────────────────────────────────────────

    /// @notice Minimum Oracle nodes required for consensus
    uint256 public constant override minNodes = 3;

    /// @notice Deviation threshold in basis points (20%)
    uint256 public constant override deviationThresholdBps = 2000;

    /// @notice Circuit breaker threshold in basis points (30%)
    uint256 public constant CIRCUIT_BREAKER_BPS = 3000;

    /// @notice Basis points denominator
    uint256 public constant BPS_DENOMINATOR = 10000;

    /// @notice Node stake requirement in MATIC (0.1 MATIC)
    uint256 public constant NODE_STAKE = 0.1 ether;

    /// @notice Wash streaming risk score threshold for Red flag (circuit breaker)
    uint256 public constant RISK_SCORE_RED = 70;

    /// @notice Wash streaming risk score threshold for Yellow flag (warning)
    uint256 public constant RISK_SCORE_YELLOW = 40;

    // ─── State Variables ───────────────────────────────────────────────────────

    /// @notice RoyaltyDistributor contract
    RoyaltyDistributor public immutable royaltyDistributor;

    /// @notice PriceFeed contract
    PriceFeed public immutable priceFeed;

    /// @notice DelistingManager contract (set after deployment)
    address public delistingManager;

    /// @notice USDC token contract
    IERC20 public immutable usdc;

    /// @notice Registered Oracle nodes
    mapping(address => bool) private _oracleNodes;

    /// @notice Node stakes
    mapping(address => uint256) public nodeStakes;

    /// @notice All registered node addresses
    address[] public nodeList;

    /// @notice Current round ID per song
    mapping(uint256 => uint256) private _currentRoundId;

    /// @notice Round data
    mapping(uint256 => RoundData) private _rounds;

    /// @notice Submissions per round (roundId => submissions)
    mapping(uint256 => OracleSubmission[]) private _submissions;

    /// @notice Whether a node has submitted for a round
    mapping(uint256 => mapping(address => bool)) public hasSubmitted;

    /// @notice Total rounds created
    uint256 public totalRounds;

    /// @notice Circuit breaker active per song
    mapping(uint256 => bool) public circuitBreakerActive;

    /// @notice Circuit breaker activation timestamp
    mapping(uint256 => uint256) public circuitBreakerActivatedAt;

    /// @notice Circuit breaker duration (72 hours)
    uint256 public constant CIRCUIT_BREAKER_DURATION = 72 hours;

    /// @notice Wash streaming risk scores per song (songId => latest risk score)
    mapping(uint256 => uint256) public washStreamingRiskScore;

    /// @notice Whether a song has an active anomaly flag (Yellow)
    mapping(uint256 => bool) public anomalyFlagged;

    /// @notice LiquidityPool addresses per song (for circuit breaker pause)
    mapping(uint256 => address) public songLiquidityPools;

    /// @notice Previous round median per song (for circuit breaker comparison)
    mapping(uint256 => uint256) public previousMedian;

    // ─── Events (additional) ──────────────────────────────────────────────────

    event WashStreamingRiskUpdated(uint256 indexed songId, uint256 riskScore, string riskLevel);
    event AnomalyFlagged(uint256 indexed songId, uint256 riskScore);
    event PoolPausedByOracle(uint256 indexed songId, address pool, string reason);

    // ─── Constructor ───────────────────────────────────────────────────────────

    /**
     * @param _royaltyDistributor RoyaltyDistributor contract address
     * @param _priceFeed          PriceFeed contract address
     * @param _usdc               USDC ERC-20 contract address
     */
    constructor(
        address _royaltyDistributor,
        address _priceFeed,
        address _usdc
    ) Ownable(msg.sender) {
        require(_royaltyDistributor != address(0), "OracleConsumer: invalid distributor");
        require(_priceFeed != address(0), "OracleConsumer: invalid price feed");
        require(_usdc != address(0), "OracleConsumer: invalid USDC");

        royaltyDistributor = RoyaltyDistributor(_royaltyDistributor);
        priceFeed = PriceFeed(_priceFeed);
        usdc = IERC20(_usdc);
    }

    // ─── Modifiers ─────────────────────────────────────────────────────────────

    modifier onlyOracleNode() {
        require(_oracleNodes[msg.sender], "OracleConsumer: caller is not an Oracle node");
        _;
    }

    // ─── External Functions ────────────────────────────────────────────────────

    /**
     * @inheritdoc IOracle
     * @dev Whitelisted Oracle nodes submit royalty data with ZK proof.
     *      After minNodes submissions, round is auto-finalized.
     */
    function submitRoyaltyData(
        uint256 songId,
        uint256 royaltyAmount,
        bytes calldata zkProof
    ) external override onlyOracleNode nonReentrant {
        require(royaltyAmount > 0, "OracleConsumer: amount must be > 0");
        require(!circuitBreakerActive[songId], "OracleConsumer: circuit breaker active");

        // Get or create round for this song
        uint256 roundId = _currentRoundId[songId];
        if (roundId == 0 || _rounds[roundId].finalized) {
            // Start new round
            roundId = ++totalRounds;
            _currentRoundId[songId] = roundId;
            _rounds[roundId] = RoundData({
                roundId: roundId,
                month: block.timestamp,
                songId: songId,
                medianRoyalty: 0,
                submissionCount: 0,
                finalized: false
            });
        }

        require(!hasSubmitted[roundId][msg.sender], "OracleConsumer: already submitted");
        require(!_rounds[roundId].finalized, "OracleConsumer: round already finalized");

        hasSubmitted[roundId][msg.sender] = true;

        // Record submission (accepted status determined after median computation)
        _submissions[roundId].push(OracleSubmission({
            node: msg.sender,
            royaltyAmount: royaltyAmount,
            timestamp: block.timestamp,
            zkProof: zkProof,
            accepted: true // Tentatively accepted; re-evaluated during finalization
        }));

        _rounds[roundId].submissionCount++;

        emit RoyaltyDataSubmitted(roundId, msg.sender, royaltyAmount, true);

        // Auto-finalize if we have enough submissions
        if (_rounds[roundId].submissionCount >= minNodes) {
            _finalizeRound(roundId);
        }
    }

    /**
     * @notice Submit royalty data with wash streaming risk score
     * @dev Extended version that includes risk score from ZK-ML fraud detection
     * @param songId        Song ID
     * @param royaltyAmount Royalty amount in USDC (6 decimals)
     * @param riskScore     Wash streaming risk score (0-100)
     * @param zkProof       ZK-ML proof bytes
     */
    function submitRoyaltyDataWithRisk(
        uint256 songId,
        uint256 royaltyAmount,
        uint256 riskScore,
        bytes calldata zkProof
    ) external onlyOracleNode nonReentrant {
        require(royaltyAmount > 0, "OracleConsumer: amount must be > 0");
        require(riskScore <= 100, "OracleConsumer: invalid risk score");
        require(!circuitBreakerActive[songId], "OracleConsumer: circuit breaker active");

        // Check risk score thresholds
        if (riskScore >= RISK_SCORE_RED) {
            // Red flag: trigger circuit breaker, refuse submission
            _triggerCircuitBreaker(songId, "Wash streaming risk score exceeded Red threshold (>70)");
            return;
        }

        if (riskScore >= RISK_SCORE_YELLOW) {
            // Yellow flag: submit with anomaly warning
            anomalyFlagged[songId] = true;
            emit AnomalyFlagged(songId, riskScore);
            emit WashStreamingRiskUpdated(songId, riskScore, "YELLOW");
        } else {
            anomalyFlagged[songId] = false;
            emit WashStreamingRiskUpdated(songId, riskScore, "GREEN");
        }

        washStreamingRiskScore[songId] = riskScore;

        // Proceed with normal submission
        _submitData(songId, royaltyAmount, zkProof);
    }

    /**
     * @notice Set liquidity pool address for a song (for circuit breaker pause)
     * @param songId Song ID
     * @param pool   LiquidityPool contract address
     */
    function setLiquidityPool(uint256 songId, address pool) external onlyOwner {
        songLiquidityPools[songId] = pool;
    }

    /**
     * @notice Force trigger circuit breaker (admin emergency)
     * @param songId Song ID
     * @param reason Reason for triggering
     */
    function triggerCircuitBreakerAdmin(uint256 songId, string calldata reason) external onlyOwner {
        _triggerCircuitBreaker(songId, reason);
    }

    /**
     * @inheritdoc IOracle
     */
    function finalizeRound(uint256 roundId) external override onlyOwner {
        require(!_rounds[roundId].finalized, "OracleConsumer: already finalized");
        require(_rounds[roundId].submissionCount >= minNodes, "OracleConsumer: insufficient submissions");
        _finalizeRound(roundId);
    }

    /**
     * @inheritdoc IOracle
     */
    function registerNode() external payable override {
        require(!_oracleNodes[msg.sender], "OracleConsumer: already registered");
        require(msg.value >= NODE_STAKE, "OracleConsumer: insufficient stake");

        _oracleNodes[msg.sender] = true;
        nodeStakes[msg.sender] = msg.value;
        nodeList.push(msg.sender);

        emit OracleNodeRegistered(msg.sender, msg.value);
    }

    /**
     * @notice Register a node without stake requirement (admin only, for testing)
     * @param node Node address to register
     */
    function registerNodeAdmin(address node) external onlyOwner {
        require(node != address(0), "OracleConsumer: invalid node");
        require(!_oracleNodes[node], "OracleConsumer: already registered");

        _oracleNodes[node] = true;
        nodeList.push(node);

        emit OracleNodeRegistered(node, 0);
    }

    /**
     * @inheritdoc IOracle
     */
    function removeNode(address node) external override onlyOwner {
        require(_oracleNodes[node], "OracleConsumer: node not registered");
        _oracleNodes[node] = false;

        // Return stake if any
        uint256 stake = nodeStakes[node];
        if (stake > 0) {
            nodeStakes[node] = 0;
            (bool success, ) = node.call{value: stake}("");
            require(success, "OracleConsumer: stake return failed");
        }

        emit OracleNodeRemoved(node);
    }

    /**
     * @notice Set DelistingManager address (called after deployment)
     * @param _delistingManager DelistingManager contract address
     */
    function setDelistingManager(address _delistingManager) external onlyOwner {
        require(_delistingManager != address(0), "OracleConsumer: invalid address");
        delistingManager = _delistingManager;
    }

    /**
     * @notice Reset circuit breaker after 72-hour review period
     * @param songId Song ID
     */
    function resetCircuitBreaker(uint256 songId) external onlyOwner {
        require(circuitBreakerActive[songId], "OracleConsumer: circuit breaker not active");
        require(
            block.timestamp >= circuitBreakerActivatedAt[songId] + CIRCUIT_BREAKER_DURATION,
            "OracleConsumer: review period not elapsed"
        );
        circuitBreakerActive[songId] = false;
    }

    // ─── Internal Functions ────────────────────────────────────────────────────

    /**
     * @notice Internal: trigger circuit breaker for a song
     */
    function _triggerCircuitBreaker(uint256 songId, string memory reason) internal {
        circuitBreakerActive[songId] = true;
        circuitBreakerActivatedAt[songId] = block.timestamp;

        // Pause the liquidity pool if it exists
        address poolAddr = songLiquidityPools[songId];
        if (poolAddr != address(0)) {
            try LiquidityPool(poolAddr).pausePool(reason) {
                emit PoolPausedByOracle(songId, poolAddr, reason);
            } catch {}
        }

        emit CircuitBreakerTriggered(songId, reason);
    }

    /**
     * @notice Internal: submit data (shared logic)
     */
    function _submitData(
        uint256 songId,
        uint256 royaltyAmount,
        bytes calldata zkProof
    ) internal {
        // Get or create round for this song
        uint256 roundId = _currentRoundId[songId];
        if (roundId == 0 || _rounds[roundId].finalized) {
            roundId = ++totalRounds;
            _currentRoundId[songId] = roundId;
            _rounds[roundId] = RoundData({
                roundId: roundId,
                month: block.timestamp,
                songId: songId,
                medianRoyalty: 0,
                submissionCount: 0,
                finalized: false
            });
        }

        require(!hasSubmitted[roundId][msg.sender], "OracleConsumer: already submitted");
        require(!_rounds[roundId].finalized, "OracleConsumer: round already finalized");

        hasSubmitted[roundId][msg.sender] = true;

        _submissions[roundId].push(OracleSubmission({
            node: msg.sender,
            royaltyAmount: royaltyAmount,
            timestamp: block.timestamp,
            zkProof: zkProof,
            accepted: true
        }));

        _rounds[roundId].submissionCount++;

        emit RoyaltyDataSubmitted(roundId, msg.sender, royaltyAmount, true);

        if (_rounds[roundId].submissionCount >= minNodes) {
            _finalizeRound(roundId);
        }
    }

    /**
     * @notice Finalize a round: compute median, reject outliers, trigger downstream
     * @param roundId Round ID to finalize
     */
    function _finalizeRound(uint256 roundId) internal {
        RoundData storage round = _rounds[roundId];
        OracleSubmission[] storage submissions = _submissions[roundId];

        uint256 n = submissions.length;
        require(n >= minNodes, "OracleConsumer: insufficient submissions");

        // Extract amounts for median computation
        uint256[] memory amounts = new uint256[](n);
        for (uint256 i = 0; i < n; i++) {
            amounts[i] = submissions[i].royaltyAmount;
        }

        // Sort amounts (insertion sort for small arrays)
        for (uint256 i = 1; i < n; i++) {
            uint256 key = amounts[i];
            uint256 j = i;
            while (j > 0 && amounts[j - 1] > key) {
                amounts[j] = amounts[j - 1];
                j--;
            }
            amounts[j] = key;
        }

        // Compute median
        uint256 median;
        if (n % 2 == 0) {
            median = (amounts[n / 2 - 1] + amounts[n / 2]) / 2;
        } else {
            median = amounts[n / 2];
        }

        round.medianRoyalty = median;

        // Reject outliers and slash nodes
        uint256 acceptedCount = 0;
        for (uint256 i = 0; i < submissions.length; i++) {
            uint256 submitted = submissions[i].royaltyAmount;
            uint256 deviation;

            if (submitted > median) {
                deviation = ((submitted - median) * BPS_DENOMINATOR) / median;
            } else {
                deviation = ((median - submitted) * BPS_DENOMINATOR) / median;
            }

            if (deviation > deviationThresholdBps) {
                // Reject and slash this node
                submissions[i].accepted = false;
                _slashNode(submissions[i].node, "Submission deviation exceeded 20%");
                emit RoyaltyDataSubmitted(roundId, submissions[i].node, submitted, false);
            } else {
                acceptedCount++;
            }
        }

        // Require minimum accepted submissions after outlier rejection
        require(acceptedCount >= minNodes, "OracleConsumer: insufficient valid submissions after filtering");

        round.finalized = true;

        emit RoundFinalized(roundId, median, acceptedCount);

        // Trigger downstream contracts
        // Check for extreme deviation from previous round (circuit breaker)
        uint256 prevMedian = previousMedian[round.songId];
        if (prevMedian > 0 && median > 0) {
            uint256 changeBps;
            if (median > prevMedian) {
                changeBps = ((median - prevMedian) * BPS_DENOMINATOR) / prevMedian;
            } else {
                changeBps = ((prevMedian - median) * BPS_DENOMINATOR) / prevMedian;
            }
            if (changeBps > CIRCUIT_BREAKER_BPS) {
                _triggerCircuitBreaker(round.songId, "Royalty deviation >30% from previous round");
                return;
            }
        }
        previousMedian[round.songId] = median;

        _triggerDownstream(round.songId, median, roundId);
    }

    /**
     * @notice Slash a node's stake for submitting outlier data
     * @param node   Node address to slash
     * @param reason Reason for slashing
     */
    function _slashNode(address node, string memory reason) internal {
        uint256 stake = nodeStakes[node];
        if (stake > 0) {
            uint256 slashAmount = stake / 2; // Slash 50% of stake
            nodeStakes[node] -= slashAmount;
            // Slashed amount goes to contract (could be sent to treasury)
            emit NodeSlashed(node, slashAmount, reason);
        }
    }

    /**
     * @notice Trigger downstream contracts after consensus
     * @param songId       Song ID
     * @param medianRoyalty Validated median royalty amount
     * @param roundId      Round ID
     */
    function _triggerDownstream(
        uint256 songId,
        uint256 medianRoyalty,
        uint256 roundId
    ) internal {
        // 1. Update fair value in PriceFeed
        // DCF fair value = monthly royalty * 12 / total supply (simplified)
        // In production, use a proper DCF model
        address musicTokenAddr = royaltyDistributor.musicTokens(songId);
        uint256 fairValue = 0;

        if (musicTokenAddr != address(0)) {
            MusicToken token = MusicToken(musicTokenAddr);
            uint256 totalSupply = token.totalSupply();
            if (totalSupply > 0) {
                // Annualized royalty / total supply = fair value per token
                fairValue = (medianRoyalty * 12 * 1e18) / totalSupply;
            }
        }

        if (fairValue > 0) {
            try priceFeed.updateFairValue(songId, fairValue, medianRoyalty) {
                // Success
            } catch {
                // Non-critical: continue even if price feed update fails
            }
        }

        // 2. Trigger royalty distribution
        // OracleConsumer must have USDC approved to pull from SPV trust
        // In production, SPV trust sends USDC to OracleConsumer first
        // For this implementation, we check if we have sufficient USDC balance
        uint256 ourBalance = usdc.balanceOf(address(this));
        if (ourBalance >= medianRoyalty) {
            // Approve RoyaltyDistributor to pull USDC
            usdc.approve(address(royaltyDistributor), medianRoyalty);
            try royaltyDistributor.receiveRoyalty(songId, medianRoyalty) {
                // Success
            } catch {
                // Non-critical: log but continue
            }
        }

        // 3. Notify DelistingManager
        if (delistingManager != address(0)) {
            try DelistingManager(delistingManager).recordMonth(songId, medianRoyalty) {
                // Success
            } catch {
                // Non-critical
            }
        }
    }

    // ─── View Functions ────────────────────────────────────────────────────────

    /// @inheritdoc IOracle
    function isOracleNode(address node) external view override returns (bool) {
        return _oracleNodes[node];
    }

    /// @inheritdoc IOracle
    function getCurrentRoundId(uint256 songId) external view override returns (uint256) {
        return _currentRoundId[songId];
    }

    /// @inheritdoc IOracle
    function getRoundData(uint256 roundId) external view override returns (RoundData memory) {
        return _rounds[roundId];
    }

    /**
     * @notice Get all submissions for a round
     * @param roundId Round ID
     */
    function getSubmissions(uint256 roundId) external view returns (OracleSubmission[] memory) {
        return _submissions[roundId];
    }

    /**
     * @notice Get total number of registered nodes
     */
    function getNodeCount() external view returns (uint256) {
        return nodeList.length;
    }

    /**
     * @notice Accept USDC deposits from SPV trust
     */
    function depositRoyaltyFunds(uint256 amount) external nonReentrant {
        require(amount > 0, "OracleConsumer: amount must be > 0");
        require(
            usdc.transferFrom(msg.sender, address(this), amount),
            "OracleConsumer: transfer failed"
        );
    }
}