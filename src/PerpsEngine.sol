// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ERC4626} from '@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol';
import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {ERC20} from '@openzeppelin/contracts/token/ERC20/ERC20.sol';
import {LiquidityPool} from "./LiquidityPool.sol";
import {AggregatorV3Interface} from "lib/chainlink-brownie-contracts/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";

contract PerpsEngine is LiquidityPool {
    // Errors
    error PerpsEngine_MaxPositionLiquidityExceeded();
    error PerpsEngine_MinNotionalValueNotMet(uint256 value, uint256 required);
    error PerpsEngine_CannotWithdrawLiquidityInUse();
    error PerpsEngine_PositionNotFound();
    error PerpsEngine_InvalidSize();
    error PerpsEngine_InvalidCollateral();
    error PerpsEngine_MaxLeverageExceeded(uint256 leverage, uint256 maxLeverage);
    error PerpsEngine_MinLeverageNotMet(uint256 leverage, uint256 minLeverage);

    // State Variables
    struct Position {
        int256 size; // Positive for long, negative for short
        uint256 collateral; // Collateral in asset tokens
        uint256 entryPrice; // Price at which position was opened
    }

    uint256 public constant MAX_UTILIZATION = 800; // 80%
    uint256 public constant UTILIZATION_PRECISION = 1000;
    uint256 public constant MAX_POSITION_LIQUIDITY = 200; // 20%
    uint256 public constant MAX_LEVERAGE = 15e18; // 15x
    uint256 public constant MIN_LEVERAGE = 1e18; // 1x
    uint256 public constant MIN_NOTIONAL_VALUE = 1e18; // $1 in 1e18 precision
    uint256 public constant PRICE_PRECISION = 1e18;

    uint256 public shortsOpenInterest; // In USD, 1e18 precision
    uint256 public longsOpenInterestInTokens; // In BTC tokens
    uint256 public reservedLiquidity; // Total collateral locked
    address public immutable wbtcPriceFeed;

    mapping(address => Position) public positions;

    IERC20 public immutable i_asset;

    constructor(IERC20 _asset, address _wbtcPriceFeed) LiquidityPool(_asset) {
        i_asset = _asset;
        wbtcPriceFeed = _wbtcPriceFeed;
    }

    // Open or modify a position
    function openPosition(int256 _size, uint256 _collateral) external {
        if (_size == 0) revert PerpsEngine_InvalidSize();
        if (_collateral == 0) revert PerpsEngine_InvalidCollateral();

        uint256 price = getPrice();
        uint256 notionalValue = uint256(_size < 0 ? -_size : _size) * price / PRICE_PRECISION;

        // Validate notional value and leverage
        if (notionalValue < MIN_NOTIONAL_VALUE) {
            revert PerpsEngine_MinNotionalValueNotMet(notionalValue, MIN_NOTIONAL_VALUE);
        }
        if (notionalValue > totalAssets() * MAX_POSITION_LIQUIDITY / UTILIZATION_PRECISION) {
            revert PerpsEngine_MaxPositionLiquidityExceeded();
        }
        uint256 totalOpenInterest = shortsOpenInterest + (longsOpenInterestInTokens * price) / PRICE_PRECISION;
        if (totalOpenInterest + notionalValue > totalAssets() * MAX_UTILIZATION / UTILIZATION_PRECISION) {
            revert PerpsEngine_MaxPositionLiquidityExceeded();
        }

        uint256 leverage = notionalValue * 1e18 / _collateral;
        if (leverage > MAX_LEVERAGE) {
            revert PerpsEngine_MaxLeverageExceeded(leverage, MAX_LEVERAGE);
        }
        if (leverage < MIN_LEVERAGE) {
            revert PerpsEngine_MinLeverageNotMet(leverage, MIN_LEVERAGE);
        }

        Position storage position = positions[msg.sender];

        // Update open interest and reserved liquidity
        if (position.size != 0) {
            // Existing position: adjust open interest
            if (position.size < 0) {
                shortsOpenInterest -= uint256(-position.size) * position.entryPrice / PRICE_PRECISION;
            } else {
                longsOpenInterestInTokens -= uint256(position.size);
            }
            reservedLiquidity -= position.collateral;
        }

        // Update position
        position.size = _size;
        position.collateral = _collateral;
        position.entryPrice = price;

        // Update open interest
        if (_size < 0) {
            shortsOpenInterest += notionalValue;
        } else {
            longsOpenInterestInTokens += uint256(_size);
        }
        reservedLiquidity += _collateral;

        // Transfer collateral
        bool success = i_asset.transferFrom(msg.sender, address(this), _collateral);
        require(success, "Collateral transfer failed");
    }

    // Increase position size
    function increasePositionSize(int256 _additionalSize) external {
        if (_additionalSize == 0) revert PerpsEngine_InvalidSize();
        Position storage position = positions[msg.sender];
        if (position.size == 0) revert PerpsEngine_PositionNotFound();

        uint256 price = getPrice();
        uint256 notionalValue = uint256(_additionalSize < 0 ? -_additionalSize : _additionalSize) * price / PRICE_PRECISION;

        // Validate liquidity constraints
        if (notionalValue > totalAssets() * MAX_POSITION_LIQUIDITY / UTILIZATION_PRECISION) {
            revert PerpsEngine_MaxPositionLiquidityExceeded();
        }
        uint256 totalOpenInterest = shortsOpenInterest + (longsOpenInterestInTokens * price) / PRICE_PRECISION;
        if (totalOpenInterest + notionalValue > totalAssets() * MAX_UTILIZATION / UTILIZATION_PRECISION) {
            revert PerpsEngine_MaxPositionLiquidityExceeded();
        }

        // Ensure new size maintains leverage constraints
        int256 newSize = position.size + _additionalSize;
        if (newSize == 0) revert PerpsEngine_InvalidSize();
        uint256 newNotionalValue = uint256(newSize < 0 ? -newSize : newSize) * price / PRICE_PRECISION;
        uint256 leverage = newNotionalValue * 1e18 / position.collateral;
        if (leverage > MAX_LEVERAGE) {
            revert PerpsEngine_MaxLeverageExceeded(leverage, MAX_LEVERAGE);
        }
        if (leverage < MIN_LEVERAGE) {
            revert PerpsEngine_MinLeverageNotMet(leverage, MIN_LEVERAGE);
        }

        // Update open interest
        if (position.size < 0) {
            shortsOpenInterest -= uint256(-position.size) * position.entryPrice / PRICE_PRECISION;
        } else {
            longsOpenInterestInTokens -= uint256(position.size);
        }

        position.size = newSize;
        position.entryPrice = price; // Update entry price to current price

        if (newSize < 0) {
            shortsOpenInterest += newNotionalValue;
        } else {
            longsOpenInterestInTokens += uint256(newSize);
        }
    }

    // Increase position collateral
    function increasePositionCollateral(uint256 _additionalCollateral) external {
        if (_additionalCollateral == 0) revert PerpsEngine_InvalidCollateral();
        Position storage position = positions[msg.sender];
        if (position.size == 0) revert PerpsEngine_PositionNotFound();

        // Update collateral and reserved liquidity
        position.collateral += _additionalCollateral;
        reservedLiquidity += _additionalCollateral;

        // Transfer additional collateral
        bool success = i_asset.transferFrom(msg.sender, address(this), _additionalCollateral);
        require(success, "Collateral transfer failed");
    }

    // Override withdraw to check reserved liquidity
    function withdraw(uint256 assets, address receiver, address owner) public override returns (uint256) {
        if (assets > totalAssets() - reservedLiquidity) {
            revert PerpsEngine_CannotWithdrawLiquidityInUse();
        }
        return super.withdraw(assets, receiver, owner);
    }

    // Override redeem to check reserved liquidity
    function redeem(uint256 shares, address receiver, address owner) public override returns (uint256) {
        uint256 assets = convertToAssets(shares);
        if (assets > totalAssets() - reservedLiquidity) {
            revert PerpsEngine_CannotWithdrawLiquidityInUse();
        }
        return super.redeem(shares, receiver, owner);
    }

    // Get real-time BTC price
    function getPrice() public view returns (uint256) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(wbtcPriceFeed);
        (, int256 price, , , ) = priceFeed.latestRoundData();
        require(price > 0, "Invalid price");
        return priceNormalised(uint256(price));
    }

    // Normalize Chainlink price (8 decimals) to 18 decimals
    function priceNormalised(uint256 price) public pure returns (uint256) {
        return price * 1e10;
    }
}