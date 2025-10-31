// SPDX-License-Identifier: MIT
/**
 * PETMEME is a community-driven meme token that celebrates the bond between humans and their pets.
 * It’s the first step toward a playful social platform where every pet can become a viral star.
 * Hold PMEME to join the cutest crypto movement ever:
 * 🐶 Share and vote for pet memes
 * 😹 Take part in viral challenges and earn rewards
 * 🐾 Collect NFT versions of your favorite pets
 * 🎉 Help build the world’s first Pet Memeverse — a social network for animals and their owners
 * https://t.me/petmeme_coin
 */
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@uniswap/v2-periphery/contracts/interfaces/IUniswapV2Router02.sol";
import "@uniswap/v2-core/contracts/interfaces/IUniswapV2Factory.sol";
import "@uniswap/v2-core/contracts/interfaces/IUniswapV2Pair.sol";
using SafeERC20 for IERC20;

error LiquidityAlreadyAdded();
error PairAlreadySeeded();
error RouterNotSet();
error EthRequired();
error InsufficientTokensForLiquidity();
error LimitsPermanentlyOff();
error MaxTxLimit();
error MaxWalletLimit();
error SellPerBlockLimit();
error RescueSelfToken();
error ZeroAddress();


contract PetMEME is ERC20, Ownable, ReentrancyGuard {

    uint256 public constant  MAX_SUPPLY        = 1000000000;
    // 30% of total supply reserved for project development, app creation, and promotion
    uint256 public constant DEV_SUPPLY = (MAX_SUPPLY * 30) / 100;

    uint16 public maxTxBps = 200;
    uint16 public maxWalletBps = 1000;

    // --- Trading fee (2%) that can be disabled in relaxAllProtections ---
    uint16 public feeBps = 200; // 2%
    bool public feesActive = true;

    bool public limitsActive = true;
    mapping(address => bool) public excludedFromLimits;

    bool public limitsPermanentOff = false;

    event LiquidityCreated(uint256 tokenAmount, uint256 ethAmount, address pair);

    event ProtectionsRelaxed(
    uint16 oldMaxTxBps, uint16 newMaxTxBps,
    uint16 oldMaxWalletBps, uint16 newMaxWalletBps,
    uint8 oldMaxSellsPerBlock, uint8 newMaxSellsPerBlock
    );

    mapping(address => uint256) private _lastSellBlock;
    mapping(address => uint8) private _sellsInBlock;

    uint8 public maxSellsPerBlock = 2;

    IUniswapV2Router02 public uniswapRouter;
    address public uniswapPair;

    constructor(address _router, address _recipient) ERC20("Pet MEME verse", "PETMEME") Ownable(msg.sender) {
        require(_router != address(0), "router=0");
        require(_recipient != address(0), "recipient=0");
        uint256 total = MAX_SUPPLY * 10 ** decimals();

        uniswapRouter = IUniswapV2Router02(_router);

        excludedFromLimits[msg.sender] = true;
        excludedFromLimits[address(this)] = true;
        excludedFromLimits[_recipient] = true;
        excludedFromLimits[address(uniswapRouter)] = true;

        _mint(address(this), total);
        _transfer(address(this), _recipient, DEV_SUPPLY * 10 ** decimals());
    }

    function addInitialLiquidity() external payable onlyOwner nonReentrant {
        if (uniswapPair != address(0)) revert LiquidityAlreadyAdded();
        address factory = uniswapRouter.factory();
        address existingPair = IUniswapV2Factory(factory).getPair(address(this), uniswapRouter.WETH());
        if (existingPair != address(0)) {
            (uint112 r0, uint112 r1, ) = IUniswapV2Pair(existingPair).getReserves();
            if (!(r0 == 0 && r1 == 0)) revert PairAlreadySeeded();
        }
        if (address(uniswapRouter) == address(0)) revert RouterNotSet();
        if (msg.value == 0) revert EthRequired();

        uint256 tokenAmount = balanceOf(address(this));
        if (tokenAmount == 0) revert InsufficientTokensForLiquidity();

        _approve(address(this), address(uniswapRouter), tokenAmount);

        uniswapRouter.addLiquidityETH{value: msg.value}(
            address(this),
            tokenAmount,
            0,
            0,
            owner(),
            block.timestamp
        );

        uniswapPair = IUniswapV2Factory(uniswapRouter.factory()).getPair(address(this), uniswapRouter.WETH());
        excludedFromLimits[uniswapPair] = true;

        emit LiquidityCreated(tokenAmount, msg.value, uniswapPair);
    }

    function relaxAllProtections() external onlyOwner {
        if (limitsPermanentOff) revert LimitsPermanentlyOff();

        uint16 oldTx = maxTxBps;
        uint16 oldWal = maxWalletBps;
        uint8  oldSells = maxSellsPerBlock;

        limitsActive = false;
        limitsPermanentOff = true;
        maxTxBps = 10000;
        maxWalletBps = 10000;
        maxSellsPerBlock = 255;
        feesActive = false;
        feeBps = 0;

        emit ProtectionsRelaxed(oldTx, maxTxBps, oldWal, maxWalletBps, oldSells, maxSellsPerBlock);
    }

    function _update(address from, address to, uint256 value) internal override {
        bool tradingStarted = (uniswapPair != address(0));
        uint256 transferAmount = value;

        uint256 totalTokens = totalSupply();
        if (tradingStarted && limitsActive && from != address(0) && to != address(0)) {
            if (!excludedFromLimits[from]) {
                uint256 maxTransferAmount = (totalTokens * maxTxBps) / 10000;
                if (value > maxTransferAmount) revert MaxTxLimit();
            }
            if (!excludedFromLimits[to]) {
                uint256 maxAllowedWalletBalance = (totalTokens * maxWalletBps) / 10000;
                uint256 currentToBalance = balanceOf(to);
                uint256 futureToBalance = (to == from) ? currentToBalance : currentToBalance + transferAmount;
                if (futureToBalance > maxAllowedWalletBalance) revert MaxWalletLimit();
            }
        }

        // --- 2% buy/sell fee, accumulated on this contract ---
        if (tradingStarted && feesActive) {
            bool isBuy = (from == uniswapPair);
            bool isSellTmp = (to == uniswapPair);

            if (isBuy) {
            // Buyer receives less; fee taken from pair->buyer transfer
                if (!excludedFromLimits[to]) {
                    uint256 feeAmount = (value * feeBps) / 10000;
                    if (feeAmount > 0) {
                        transferAmount = value - feeAmount;
                        super._update(from, address(this), feeAmount);
                    }
                }
            } else if (isSellTmp) {
        // Seller sends more; fee taken from seller->pair transfer
            if (!excludedFromLimits[from]) {
                uint256 feeAmount = (value * feeBps) / 10000;
                if (feeAmount > 0) {
                    transferAmount = value - feeAmount;
                    super._update(from, address(this), feeAmount);
                }
            }
        }
        }

        bool isSell = (to == uniswapPair);
        if (tradingStarted && from != address(0) && isSell && !excludedFromLimits[from]) {
            if (_lastSellBlock[from] == block.number) {
                unchecked { _sellsInBlock[from]++; }
                if (_sellsInBlock[from] > maxSellsPerBlock) revert SellPerBlockLimit();
            } else {
            _lastSellBlock[from] = block.number;
            _sellsInBlock[from] = 1;
        }
        }

        super._update(from, to, transferAmount);
    }

    function withdrawCollectedFees(address to, uint256 amount) external onlyOwner nonReentrant {
        require(limitsPermanentOff, "protections on");
        if (to == address(0)) revert ZeroAddress();
        _transfer(address(this), to, amount);
    }

    function rescueERC20(address token, address to, uint256 amount) external onlyOwner nonReentrant {
        if (token == address(this)) revert RescueSelfToken();
        if (to == address(0)) revert ZeroAddress();
        IERC20(token).safeTransfer(to, amount);
    }

    receive() external payable {}
}
