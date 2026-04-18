// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title IMusicToken
 * @notice Interface for MusicToken ERC-20 contract representing tokenised song royalty rights
 */
interface IMusicToken {
    // ─── Events ───────────────────────────────────────────────────────────────

    event TokensPurchased(address indexed buyer, uint256 amount, uint256 usdcPaid);
    event RoyaltyShareUpdated(uint256 newShareBps);

    // ─── View Functions ────────────────────────────────────────────────────────

    /// @notice Returns the artist wallet address that receives non-distributed royalties
    function artistWallet() external view returns (address);

    /// @notice Returns the total royalty share sold to investors in basis points (e.g. 3000 = 30%)
    function royaltyShareSoldBps() external view returns (uint256);

    /// @notice Returns the issuance fair value per token in USDC (6 decimals)
    function issuanceFairValue() external view returns (uint256);

    /// @notice Returns the song metadata URI
    function songURI() external view returns (string memory);

    /// @notice Returns the USDC token address used for purchases
    function usdcToken() external view returns (address);

    /// @notice Returns the listing manager address
    function listingManager() external view returns (address);

    /// @notice Returns the total USDC raised during issuance
    function totalUsdcRaised() external view returns (uint256);

    /// @notice Returns whether the token sale is still active
    function saleActive() external view returns (bool);

    // ─── State-Changing Functions ──────────────────────────────────────────────

    /**
     * @notice Purchase tokens with USDC during the issuance phase
     * @param usdcAmount Amount of USDC to spend (6 decimals)
     */
    function purchaseTokens(uint256 usdcAmount) external;

    /**
     * @notice Close the token sale (called by ListingManager after funding goal met)
     */
    function closeSale() external;

    /**
     * @notice Returns the balance of a specific holder
     * @param holder Address of the token holder
     */
    function balanceOf(address holder) external view returns (uint256);

    /**
     * @notice Returns the total supply of tokens
     */
    function totalSupply() external view returns (uint256);
}
