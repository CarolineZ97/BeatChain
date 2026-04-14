// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";

/**
 * @title LiquidityPool
 * @notice Uniswap v2 风格的常数乘积 AMM 池，每首歌曲代币对应一个 USDC/Token 池。
 *
 * 核心公式: x * y = k
 *   x = USDC 储备量
 *   y = 歌曲代币储备量
 *   k = 常数乘积
 *
 * 功能:
 *  - swap(): 投资者可随时买卖歌曲代币
 *  - addLiquidity(): LP 提供者添加流动性
 *  - removeLiquidity(): LP 提供者移除流动性
 *  - getMarketPrice(): 获取当前市场价格
 *  - pausePool(): 熔断时暂停交易
 *
 * 费用: 每笔交易收取 0.3% 手续费，分配给 LP 提供者
 *
 * 交易保护:
 *  - Oracle Red Flag (wash streaming 风险 > 70): 暂停交易
 *  - 公允价值变化 > 50%: 暂停交易最多 3 个工作日
 *  - 退市警告: 7 天补救期内继续交易，正式退市后暂停
 */
contract LiquidityPool is ERC20, Ownable, ReentrancyGuard {
    // ─── Constants ─────────────────────────────────────────────────────────────

    /// @notice 交易手续费 (0.3% = 30 basis points)
    uint256 public constant SWAP_FEE_BPS = 30;

    /// @notice Basis points 分母
    uint256 public constant BPS_DENOMINATOR = 10000;

    /// @notice 最小流动性（防止首次添加流动性时的精度攻击）
    uint256 public constant MINIMUM_LIQUIDITY = 1000;

    // ─── State Variables ───────────────────────────────────────────────────────

    /// @notice USDC 代币合约
    IERC20 public immutable usdc;

    /// @notice 歌曲代币合约
    IERC20 public immutable songToken;

    /// @notice 歌曲 ID
    uint256 public immutable songId;

    /// @notice USDC 储备量
    uint256 public reserveUSDC;

    /// @notice 歌曲代币储备量
    uint256 public reserveToken;

    /// @notice 池是否暂停
    bool public paused;

    /// @notice 暂停原因
    string public pauseReason;

    /// @notice 暂停时间戳
    uint256 public pausedAt;

    /// @notice 授权调用者（LiquidityBootstrap, DelistingManager 等）
    mapping(address => bool) public authorizedCallers;

    /// @notice 累计交易量（USDC 计价）
    uint256 public totalVolumeUSDC;

    /// @notice 每日交易量追踪（天 => 交易量）
    mapping(uint256 => uint256) public dailyVolume;

    // ─── Events ───────────────────────────────────────────────────────────────

    event LiquidityAdded(
        address indexed provider,
        uint256 usdcAmount,
        uint256 tokenAmount,
        uint256 lpTokensMinted
    );
    event LiquidityRemoved(
        address indexed provider,
        uint256 usdcAmount,
        uint256 tokenAmount,
        uint256 lpTokensBurned
    );
    event Swap(
        address indexed trader,
        bool usdcToToken,
        uint256 amountIn,
        uint256 amountOut,
        uint256 feeAmount
    );
    event PoolPaused(string reason, uint256 timestamp);
    event PoolResumed(uint256 timestamp);

    // ─── Constructor ───────────────────────────────────────────────────────────

    /**
     * @param _usdc      USDC ERC-20 合约地址
     * @param _songToken 歌曲代币合约地址
     * @param _songId    歌曲 ID
     */
    constructor(
        address _usdc,
        address _songToken,
        uint256 _songId
    ) ERC20(
        string(abi.encodePacked("BeatChain LP - Song #", _toString(_songId))),
        string(abi.encodePacked("BCLP-", _toString(_songId)))
    ) Ownable(msg.sender) {
        require(_usdc != address(0), "LiquidityPool: invalid USDC");
        require(_songToken != address(0), "LiquidityPool: invalid song token");

        usdc = IERC20(_usdc);
        songToken = IERC20(_songToken);
        songId = _songId;
    }

    // ─── Modifiers ─────────────────────────────────────────────────────────────

    modifier whenNotPaused() {
        require(!paused, "LiquidityPool: pool is paused");
        _;
    }

    modifier onlyAuthorized() {
        require(
            authorizedCallers[msg.sender] || msg.sender == owner(),
            "LiquidityPool: caller not authorized"
        );
        _;
    }

    // ─── External Functions ────────────────────────────────────────────────────

    /**
     * @notice 添加流动性
     * @dev 调用者必须先 approve USDC 和歌曲代币给本合约
     * @param usdcAmount  USDC 数量
     * @param tokenAmount 歌曲代币数量
     * @return lpTokens   铸造的 LP 代币数量
     */
    function addLiquidity(
        uint256 usdcAmount,
        uint256 tokenAmount
    ) external nonReentrant whenNotPaused returns (uint256 lpTokens) {
        require(usdcAmount > 0 && tokenAmount > 0, "LiquidityPool: amounts must be > 0");

        uint256 _totalSupply = totalSupply();

        if (_totalSupply == 0) {
            // 首次添加流动性
            lpTokens = _sqrt(usdcAmount * tokenAmount) - MINIMUM_LIQUIDITY;
            // 锁定最小流动性（发送到零地址）
            _mint(address(1), MINIMUM_LIQUIDITY);
        } else {
            // 按比例添加
            uint256 lpFromUSDC = (usdcAmount * _totalSupply) / reserveUSDC;
            uint256 lpFromToken = (tokenAmount * _totalSupply) / reserveToken;
            lpTokens = lpFromUSDC < lpFromToken ? lpFromUSDC : lpFromToken;
        }

        require(lpTokens > 0, "LiquidityPool: insufficient liquidity minted");

        // 转入资产
        require(
            usdc.transferFrom(msg.sender, address(this), usdcAmount),
            "LiquidityPool: USDC transfer failed"
        );
        require(
            songToken.transferFrom(msg.sender, address(this), tokenAmount),
            "LiquidityPool: token transfer failed"
        );

        // 更新储备
        reserveUSDC += usdcAmount;
        reserveToken += tokenAmount;

        // 铸造 LP 代币
        _mint(msg.sender, lpTokens);

        emit LiquidityAdded(msg.sender, usdcAmount, tokenAmount, lpTokens);
    }

    /**
     * @notice 移除流动性
     * @param lpTokenAmount 要销毁的 LP 代币数量
     * @return usdcAmount   返还的 USDC 数量
     * @return tokenAmount  返还的歌曲代币数量
     */
    function removeLiquidity(
        uint256 lpTokenAmount
    ) external nonReentrant returns (uint256 usdcAmount, uint256 tokenAmount) {
        require(lpTokenAmount > 0, "LiquidityPool: amount must be > 0");
        require(balanceOf(msg.sender) >= lpTokenAmount, "LiquidityPool: insufficient LP tokens");

        uint256 _totalSupply = totalSupply();

        // 按比例计算返还金额
        usdcAmount = (lpTokenAmount * reserveUSDC) / _totalSupply;
        tokenAmount = (lpTokenAmount * reserveToken) / _totalSupply;

        require(usdcAmount > 0 && tokenAmount > 0, "LiquidityPool: insufficient liquidity burned");

        // 销毁 LP 代币
        _burn(msg.sender, lpTokenAmount);

        // 更新储备
        reserveUSDC -= usdcAmount;
        reserveToken -= tokenAmount;

        // 转出资产
        require(usdc.transfer(msg.sender, usdcAmount), "LiquidityPool: USDC transfer failed");
        require(songToken.transfer(msg.sender, tokenAmount), "LiquidityPool: token transfer failed");

        emit LiquidityRemoved(msg.sender, usdcAmount, tokenAmount, lpTokenAmount);
    }

    /**
     * @notice 用 USDC 购买歌曲代币
     * @param usdcAmountIn  输入的 USDC 数量
     * @param minTokenOut   最小输出代币数量（滑点保护）
     * @return tokenAmountOut 输出的歌曲代币数量
     */
    function swapUSDCForToken(
        uint256 usdcAmountIn,
        uint256 minTokenOut
    ) external nonReentrant whenNotPaused returns (uint256 tokenAmountOut) {
        require(usdcAmountIn > 0, "LiquidityPool: amount must be > 0");
        require(reserveUSDC > 0 && reserveToken > 0, "LiquidityPool: no liquidity");

        // 计算手续费
        uint256 fee = (usdcAmountIn * SWAP_FEE_BPS) / BPS_DENOMINATOR;
        uint256 usdcAmountInAfterFee = usdcAmountIn - fee;

        // 常数乘积公式: (x + dx) * (y - dy) = x * y
        // dy = y * dx / (x + dx)
        tokenAmountOut = (reserveToken * usdcAmountInAfterFee) / (reserveUSDC + usdcAmountInAfterFee);

        require(tokenAmountOut >= minTokenOut, "LiquidityPool: slippage exceeded");
        require(tokenAmountOut < reserveToken, "LiquidityPool: insufficient reserve");

        // 转入 USDC
        require(
            usdc.transferFrom(msg.sender, address(this), usdcAmountIn),
            "LiquidityPool: USDC transfer failed"
        );

        // 转出歌曲代币
        require(
            songToken.transfer(msg.sender, tokenAmountOut),
            "LiquidityPool: token transfer failed"
        );

        // 更新储备（手续费留在池中，增加 LP 价值）
        reserveUSDC += usdcAmountIn;
        reserveToken -= tokenAmountOut;

        // 记录交易量
        totalVolumeUSDC += usdcAmountIn;
        uint256 today = block.timestamp / 1 days;
        dailyVolume[today] += usdcAmountIn;

        emit Swap(msg.sender, true, usdcAmountIn, tokenAmountOut, fee);
    }

    /**
     * @notice 卖出歌曲代币换取 USDC
     * @param tokenAmountIn 输入的歌曲代币数量
     * @param minUsdcOut    最小输出 USDC 数量（滑点保护）
     * @return usdcAmountOut 输出的 USDC 数量
     */
    function swapTokenForUSDC(
        uint256 tokenAmountIn,
        uint256 minUsdcOut
    ) external nonReentrant whenNotPaused returns (uint256 usdcAmountOut) {
        require(tokenAmountIn > 0, "LiquidityPool: amount must be > 0");
        require(reserveUSDC > 0 && reserveToken > 0, "LiquidityPool: no liquidity");

        // 计算手续费（以代币计）
        uint256 fee = (tokenAmountIn * SWAP_FEE_BPS) / BPS_DENOMINATOR;
        uint256 tokenAmountInAfterFee = tokenAmountIn - fee;

        // 常数乘积公式
        usdcAmountOut = (reserveUSDC * tokenAmountInAfterFee) / (reserveToken + tokenAmountInAfterFee);

        require(usdcAmountOut >= minUsdcOut, "LiquidityPool: slippage exceeded");
        require(usdcAmountOut < reserveUSDC, "LiquidityPool: insufficient reserve");

        // 转入歌曲代币
        require(
            songToken.transferFrom(msg.sender, address(this), tokenAmountIn),
            "LiquidityPool: token transfer failed"
        );

        // 转出 USDC
        require(usdc.transfer(msg.sender, usdcAmountOut), "LiquidityPool: USDC transfer failed");

        // 更新储备
        reserveToken += tokenAmountIn;
        reserveUSDC -= usdcAmountOut;

        // 记录交易量
        totalVolumeUSDC += usdcAmountOut;
        uint256 today = block.timestamp / 1 days;
        dailyVolume[today] += usdcAmountOut;

        emit Swap(msg.sender, false, tokenAmountIn, usdcAmountOut, fee);
    }

    /**
     * @notice 暂停池交易（熔断机制）
     * @param reason 暂停原因
     */
    function pausePool(string calldata reason) external onlyAuthorized {
        paused = true;
        pauseReason = reason;
        pausedAt = block.timestamp;
        emit PoolPaused(reason, block.timestamp);
    }

    /**
     * @notice 恢复池交易
     */
    function resumePool() external onlyAuthorized {
        require(paused, "LiquidityPool: pool not paused");
        paused = false;
        pauseReason = "";
        emit PoolResumed(block.timestamp);
    }

    /**
     * @notice 设置授权调用者
     */
    function setAuthorizedCaller(address caller, bool status) external onlyOwner {
        require(caller != address(0), "LiquidityPool: invalid caller");
        authorizedCallers[caller] = status;
    }

    // ─── View Functions ────────────────────────────────────────────────────────

    /**
     * @notice 获取当前市场价格（每个歌曲代币的 USDC 价格）
     * @return price 价格（USDC，6 位小数）
     */
    function getMarketPrice() external view returns (uint256 price) {
        if (reserveToken == 0) return 0;
        // price = reserveUSDC / reserveToken (调整精度)
        price = (reserveUSDC * 1e18) / reserveToken;
    }

    /**
     * @notice 获取买入报价（用 USDC 买代币）
     * @param usdcAmountIn 输入 USDC 数量
     * @return tokenAmountOut 预计输出代币数量
     */
    function getTokenAmountOut(uint256 usdcAmountIn) external view returns (uint256 tokenAmountOut) {
        if (reserveUSDC == 0 || reserveToken == 0) return 0;
        uint256 fee = (usdcAmountIn * SWAP_FEE_BPS) / BPS_DENOMINATOR;
        uint256 amountInAfterFee = usdcAmountIn - fee;
        tokenAmountOut = (reserveToken * amountInAfterFee) / (reserveUSDC + amountInAfterFee);
    }

    /**
     * @notice 获取卖出报价（卖代币换 USDC）
     * @param tokenAmountIn 输入代币数量
     * @return usdcAmountOut 预计输出 USDC 数量
     */
    function getUsdcAmountOut(uint256 tokenAmountIn) external view returns (uint256 usdcAmountOut) {
        if (reserveUSDC == 0 || reserveToken == 0) return 0;
        uint256 fee = (tokenAmountIn * SWAP_FEE_BPS) / BPS_DENOMINATOR;
        uint256 amountInAfterFee = tokenAmountIn - fee;
        usdcAmountOut = (reserveUSDC * amountInAfterFee) / (reserveToken + amountInAfterFee);
    }

    /**
     * @notice 计算滑点百分比（basis points）
     * @param usdcAmountIn 输入 USDC 数量
     * @return slippageBps 滑点（basis points）
     */
    function getSlippage(uint256 usdcAmountIn) external view returns (uint256 slippageBps) {
        if (reserveUSDC == 0 || reserveToken == 0) return BPS_DENOMINATOR;

        // 理想价格（无滑点）
        uint256 idealOut = (usdcAmountIn * reserveToken) / reserveUSDC;
        // 实际输出
        uint256 fee = (usdcAmountIn * SWAP_FEE_BPS) / BPS_DENOMINATOR;
        uint256 amountInAfterFee = usdcAmountIn - fee;
        uint256 actualOut = (reserveToken * amountInAfterFee) / (reserveUSDC + amountInAfterFee);

        if (idealOut == 0) return BPS_DENOMINATOR;
        slippageBps = ((idealOut - actualOut) * BPS_DENOMINATOR) / idealOut;
    }

    /**
     * @notice 获取过去 N 天的平均日交易量
     * @param days_ 天数
     * @return avgVolume 平均日交易量（USDC）
     */
    function getAverageDailyVolume(uint256 days_) external view returns (uint256 avgVolume) {
        if (days_ == 0) return 0;
        uint256 today = block.timestamp / 1 days;
        uint256 totalVolume = 0;
        for (uint256 i = 0; i < days_; i++) {
            totalVolume += dailyVolume[today - i];
        }
        avgVolume = totalVolume / days_;
    }

    /**
     * @notice 获取储备量
     */
    function getReserves() external view returns (uint256 _reserveUSDC, uint256 _reserveToken) {
        return (reserveUSDC, reserveToken);
    }

    // ─── Internal Functions ────────────────────────────────────────────────────

    /**
     * @notice 整数平方根（Babylonian method）
     */
    function _sqrt(uint256 y) internal pure returns (uint256 z) {
        if (y > 3) {
            z = y;
            uint256 x = y / 2 + 1;
            while (x < z) {
                z = x;
                x = (y / x + x) / 2;
            }
        } else if (y != 0) {
            z = 1;
        }
    }

    /**
     * @notice uint256 转字符串
     */
    function _toString(uint256 value) internal pure returns (string memory) {
        if (value == 0) return "0";
        uint256 temp = value;
        uint256 digits;
        while (temp != 0) {
            digits++;
            temp /= 10;
        }
        bytes memory buffer = new bytes(digits);
        while (value != 0) {
            digits -= 1;
            buffer[digits] = bytes1(uint8(48 + uint256(value % 10)));
            value /= 10;
        }
        return string(buffer);
    }
}
