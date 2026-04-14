// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";

/**
 * @title PlatformTreasury
 * @notice Receives and holds platform fees collected from:
 *         - 3% issuance fee (from MusicToken purchases)
 *         - 1% distribution fee (from RoyaltyDistributor)
 *
 * Only the platform admin wallet can withdraw accumulated fees.
 * Supports both USDC and native MATIC withdrawals.
 */
contract PlatformTreasury is Ownable, ReentrancyGuard {
    // ─── Events ───────────────────────────────────────────────────────────────

    event FeeReceived(address indexed token, address indexed from, uint256 amount);
    event FeeWithdrawn(address indexed token, address indexed to, uint256 amount);
    event AdminUpdated(address indexed oldAdmin, address indexed newAdmin);

    // ─── State Variables ───────────────────────────────────────────────────────

    /// @notice Platform admin wallet — only address that can withdraw fees
    address public platformAdmin;

    /// @notice Accumulated fees per token address
    mapping(address => uint256) public accumulatedFees;

    /// @notice Total fees received per token (historical)
    mapping(address => uint256) public totalFeesReceived;

    // ─── Constructor ───────────────────────────────────────────────────────────

    /**
     * @param _platformAdmin Initial platform admin wallet address
     */
    constructor(address _platformAdmin) Ownable(msg.sender) {
        require(_platformAdmin != address(0), "PlatformTreasury: invalid admin address");
        platformAdmin = _platformAdmin;
    }

    // ─── Modifiers ─────────────────────────────────────────────────────────────

    modifier onlyAdmin() {
        require(msg.sender == platformAdmin, "PlatformTreasury: caller is not admin");
        _;
    }

    // ─── External Functions ────────────────────────────────────────────────────

    /**
     * @notice Deposit ERC-20 fee tokens into the treasury
     * @dev Called by MusicToken (issuance fee) and RoyaltyDistributor (distribution fee)
     * @param token ERC-20 token address (typically USDC)
     * @param amount Amount to deposit (6 decimals for USDC)
     */
    function depositFee(address token, uint256 amount) external nonReentrant {
        require(token != address(0), "PlatformTreasury: invalid token");
        require(amount > 0, "PlatformTreasury: amount must be > 0");

        require(
            IERC20(token).transferFrom(msg.sender, address(this), amount),
            "PlatformTreasury: transfer failed"
        );

        accumulatedFees[token] += amount;
        totalFeesReceived[token] += amount;

        emit FeeReceived(token, msg.sender, amount);
    }

    /**
     * @notice Withdraw accumulated ERC-20 fees to a specified address
     * @dev Only callable by platform admin
     * @param token ERC-20 token address
     * @param to Recipient address
     * @param amount Amount to withdraw
     */
    function withdrawFee(
        address token,
        address to,
        uint256 amount
    ) external onlyAdmin nonReentrant {
        require(token != address(0), "PlatformTreasury: invalid token");
        require(to != address(0), "PlatformTreasury: invalid recipient");
        require(amount > 0, "PlatformTreasury: amount must be > 0");
        require(accumulatedFees[token] >= amount, "PlatformTreasury: insufficient balance");

        accumulatedFees[token] -= amount;

        require(
            IERC20(token).transfer(to, amount),
            "PlatformTreasury: transfer failed"
        );

        emit FeeWithdrawn(token, to, amount);
    }

    /**
     * @notice Withdraw all accumulated fees for a token to admin wallet
     * @param token ERC-20 token address
     */
    function withdrawAllFees(address token) external onlyAdmin nonReentrant {
        uint256 amount = accumulatedFees[token];
        require(amount > 0, "PlatformTreasury: no fees to withdraw");

        accumulatedFees[token] = 0;

        require(
            IERC20(token).transfer(platformAdmin, amount),
            "PlatformTreasury: transfer failed"
        );

        emit FeeWithdrawn(token, platformAdmin, amount);
    }

    /**
     * @notice Update the platform admin wallet
     * @dev Only callable by current owner (deployer)
     * @param newAdmin New admin wallet address
     */
    function updateAdmin(address newAdmin) external onlyOwner {
        require(newAdmin != address(0), "PlatformTreasury: invalid admin address");
        address oldAdmin = platformAdmin;
        platformAdmin = newAdmin;
        emit AdminUpdated(oldAdmin, newAdmin);
    }

    /**
     * @notice Returns the current balance of a specific token held by treasury
     * @param token ERC-20 token address
     */
    function getBalance(address token) external view returns (uint256) {
        return IERC20(token).balanceOf(address(this));
    }

    /**
     * @notice Accept native MATIC deposits (in case of MATIC fee collection)
     */
    receive() external payable {
        emit FeeReceived(address(0), msg.sender, msg.value);
    }

    /**
     * @notice Withdraw native MATIC to admin
     */
    function withdrawMatic(uint256 amount) external onlyAdmin nonReentrant {
        require(amount <= address(this).balance, "PlatformTreasury: insufficient MATIC");
        (bool success, ) = platformAdmin.call{value: amount}("");
        require(success, "PlatformTreasury: MATIC transfer failed");
        emit FeeWithdrawn(address(0), platformAdmin, amount);
    }
}
