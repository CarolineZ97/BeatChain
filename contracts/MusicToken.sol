// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "./interfaces/IMusicToken.sol";

/**
 * @title MusicToken
 * @notice ERC-20 token representing tokenised streaming royalty rights for a single song.
 *         One instance is deployed per song via ListingManager.
 *
 * Key parameters stored per instance:
 *  - artistWallet:        receives non-distributed royalties
 *  - royaltyShareSoldBps: percentage of royalty rights sold to investors (max 5000 = 50%)
 *  - issuanceFairValue:   price per token in USDC at issuance (6 decimals)
 *  - totalUsdcRaised:     total USDC collected from investors
 *
 * Business rules:
 *  - Artist cannot sell more than 50% of royalty rights (MAX_ROYALTY_SHARE_BPS = 5000)
 *  - 3% platform issuance fee is deducted from funds raised and sent to PlatformTreasury
 *  - Remaining 97% is forwarded to the artist wallet
 */
contract MusicToken is ERC20, Ownable, ReentrancyGuard, IMusicToken {
    // ─── Constants ─────────────────────────────────────────────────────────────

    /// @notice Maximum royalty share that can be sold (50% in basis points)
    uint256 public constant MAX_ROYALTY_SHARE_BPS = 5000;

    /// @notice Platform issuance fee in basis points (3%)
    uint256 public constant ISSUANCE_FEE_BPS = 300;

    /// @notice Basis points denominator
    uint256 public constant BPS_DENOMINATOR = 10000;

    // ─── State Variables ───────────────────────────────────────────────────────

    /// @inheritdoc IMusicToken
    address public override artistWallet;

    /// @inheritdoc IMusicToken
    uint256 public override royaltyShareSoldBps;

    /// @inheritdoc IMusicToken
    uint256 public override issuanceFairValue;

    /// @inheritdoc IMusicToken
    string public override songURI;

    /// @inheritdoc IMusicToken
    address public override usdcToken;

    /// @inheritdoc IMusicToken
    address public override listingManager;

    /// @inheritdoc IMusicToken
    uint256 public override totalUsdcRaised;

    /// @inheritdoc IMusicToken
    bool public override saleActive;

    /// @notice Platform treasury address to receive issuance fees
    address public platformTreasury;

    /// @notice Song ID assigned by ListingManager
    uint256 public songId;

    /// @notice Funding goal in USDC (6 decimals)
    uint256 public fundingGoal;

    // ─── Constructor ───────────────────────────────────────────────────────────

    /**
     * @param _name          Token name (e.g. "Song Title Token")
     * @param _symbol        Token symbol (e.g. "SONG1")
     * @param _totalSupply   Total token supply (18 decimals)
     * @param _artistWallet  Artist's wallet address
     * @param _royaltyShareSoldBps Percentage of royalty rights sold (max 5000)
     * @param _issuanceFairValue   Price per token in USDC (6 decimals)
     * @param _songURI       Metadata URI for the song
     * @param _usdcToken     USDC ERC-20 contract address
     * @param _platformTreasury Platform treasury address
     * @param _songId        Unique song ID
     * @param _fundingGoal   Total USDC to raise (6 decimals)
     */
    constructor(
        string memory _name,
        string memory _symbol,
        uint256 _totalSupply,
        address _artistWallet,
        uint256 _royaltyShareSoldBps,
        uint256 _issuanceFairValue,
        string memory _songURI,
        address _usdcToken,
        address _platformTreasury,
        uint256 _songId,
        uint256 _fundingGoal
    ) ERC20(_name, _symbol) Ownable(msg.sender) {
        require(_artistWallet != address(0), "MusicToken: invalid artist wallet");
        require(_royaltyShareSoldBps <= MAX_ROYALTY_SHARE_BPS, "MusicToken: exceeds max royalty share");
        require(_royaltyShareSoldBps > 0, "MusicToken: royalty share must be > 0");
        require(_issuanceFairValue > 0, "MusicToken: issuance fair value must be > 0");
        require(_usdcToken != address(0), "MusicToken: invalid USDC address");
        require(_platformTreasury != address(0), "MusicToken: invalid treasury address");
        require(_totalSupply > 0, "MusicToken: total supply must be > 0");

        artistWallet = _artistWallet;
        royaltyShareSoldBps = _royaltyShareSoldBps;
        issuanceFairValue = _issuanceFairValue;
        songURI = _songURI;
        usdcToken = _usdcToken;
        platformTreasury = _platformTreasury;
        songId = _songId;
        fundingGoal = _fundingGoal;
        listingManager = msg.sender;
        saleActive = true;

        // Mint all tokens to this contract for sale
        _mint(address(this), _totalSupply);
    }

    // ─── Modifiers ─────────────────────────────────────────────────────────────

    modifier onlySaleActive() {
        require(saleActive, "MusicToken: sale is not active");
        _;
    }

    // ─── External Functions ────────────────────────────────────────────────────

    /**
     * @inheritdoc IMusicToken
     * @dev Investor sends USDC, receives proportional tokens.
     *      3% platform fee is deducted and sent to PlatformTreasury.
     *      Remaining 97% is forwarded to artist wallet.
     */
    function purchaseTokens(uint256 usdcAmount) external override nonReentrant onlySaleActive {
        require(usdcAmount > 0, "MusicToken: amount must be > 0");

        // Calculate tokens to mint based on issuance fair value
        // usdcAmount is in 6 decimals, issuanceFairValue is in 6 decimals
        // tokenAmount is in 18 decimals
        uint256 tokenAmount = (usdcAmount * 1e18) / issuanceFairValue;
        require(tokenAmount > 0, "MusicToken: token amount too small");
        require(
            balanceOf(address(this)) >= tokenAmount,
            "MusicToken: insufficient tokens remaining"
        );

        // Transfer USDC from buyer to this contract
        require(
            IERC20(usdcToken).transferFrom(msg.sender, address(this), usdcAmount),
            "MusicToken: USDC transfer failed"
        );

        totalUsdcRaised += usdcAmount;

        // Deduct 3% platform issuance fee
        uint256 platformFee = (usdcAmount * ISSUANCE_FEE_BPS) / BPS_DENOMINATOR;
        uint256 artistProceeds = usdcAmount - platformFee;

        // Send platform fee to treasury
        require(
            IERC20(usdcToken).transfer(platformTreasury, platformFee),
            "MusicToken: fee transfer failed"
        );

        // Send remaining USDC to artist
        require(
            IERC20(usdcToken).transfer(artistWallet, artistProceeds),
            "MusicToken: artist transfer failed"
        );

        // Transfer tokens to buyer
        _transfer(address(this), msg.sender, tokenAmount);

        emit TokensPurchased(msg.sender, tokenAmount, usdcAmount);

        // Auto-close sale if funding goal reached
        if (totalUsdcRaised >= fundingGoal) {
            _closeSale();
        }
    }

    /**
     * @inheritdoc IMusicToken
     * @dev Can only be called by the listing manager (owner)
     */
    function closeSale() external override onlyOwner {
        _closeSale();
    }

    // ─── Internal Functions ────────────────────────────────────────────────────

    function _closeSale() internal {
        saleActive = false;
        // Burn any unsold tokens
        uint256 unsold = balanceOf(address(this));
        if (unsold > 0) {
            _burn(address(this), unsold);
        }
    }

    // ─── View Functions ────────────────────────────────────────────────────────

    /**
     * @notice Returns the number of tokens remaining for sale
     */
    function tokensRemaining() external view returns (uint256) {
        return balanceOf(address(this));
    }

    /**
     * @notice Returns the USDC amount needed to purchase a given token amount
     * @param tokenAmount Token amount (18 decimals)
     */
    function getUsdcCost(uint256 tokenAmount) external view returns (uint256) {
        return (tokenAmount * issuanceFairValue) / 1e18;
    }
}
