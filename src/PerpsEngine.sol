// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ERC4626} from '@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol';
import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {ERC20} from '@openzeppelin/contracts/token/ERC20/ERC20.sol';
import {LiquidityPool} from "./LiquidityPool.sol";
import {AggregatorV3Interface} from "lib/chainlink-brownie-contracts/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";
import {SignedMath} from "@openzeppelin/contracts/utils/math/SignedMath.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

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

    using SafeCast for int256;
    using SafeCast for uint256;
    using SignedMath for int256;
    using SafeERC20 for IERC20;

    // State Variables
    struct Position {
        uint256 sizeInUSD;
        uint256 sizeInTokens;
        uint256 collateralAmount;
        uint256 lastUpdatedAt;
    }

    address public indexToken;
    address public btcPriceFeed;

    uint256 public totalCollateral;
    uint256 public totalDeposits;

    uint256 public OILong;
    uint256 public OIShort;
    uint256 public OILongInTokens;
    uint256 public OIShortInTokens;

    mapping (address => Position) public longPositions;
    mapping (address => Position) public shortPositions;

    uint256 public maxUtilizationRatio = 5e29;
    uint256 public maxLeverage = 20e30;


    uint256 public constant PRECISION = 1e30;


    constructor(address _indexToken, IERC20 _collateralToken, address _btcPriceFeed) LiquidityPool(_collateralToken) {
        indexToken = _indexToken;
        btcPriceFeed=_btcPriceFeed;

    }

    function getPosition(bool isLong, address user) public view returns (Position memory) {
        return isLong ? longPositions[user] : shortPositions[user];
    }

    function getNetPnL(bool isLong, uint256 indexPrice) public view returns(int256 pnl) {
        if(isLong) {
            pnl = int256(OILongInTokens * indexPrice) - int256(OILong);
        }
        else {
            pnl = int256(OIShort) - int256(OIShortInTokens * indexPrice); // because OIShort is most amount of money you either lose or gain
        }
    }

    function totalAssets() public view override returns (uint256) {
        uint256 _totalDeposits = totalDeposits;
        uint256 indexPrice = getPrice();

        int256 traderPnlLong = getNetPnL(true,indexPrice);
        int256 traderPnlShort = getNetPnL(false,indexPrice);

        int256 traderNetPnl = (traderPnlLong + traderPnlShort)/ int256(1e24);

        if(traderNetPnl > 0) {
            if(traderNetPnl.toUint256() > _totalDeposits ) revert("Trader PnL exceeds deposits");
            return _totalDeposits - traderNetPnl.toUint256();
        }
        else return _totalDeposits + (-traderNetPnl).toUint256();
    }


    function increasePosition(bool isLong, uint256 sizeDelta, uint256 collateralDelta) public  {
        if(collateralDelta > 0) IERC20(asset()).safeTransferFrom(msg.sender,address(this),collateralDelta);

        mapping (address => Position) storage positions = isLong ? longPositions : shortPositions;
        Position memory position = positions[msg.sender];

        uint256 indexTokenPrice = getPrice();
        uint256 indexTokenDelta = isLong ? sizeDelta / indexTokenPrice : Math.ceilDiv(sizeDelta,indexTokenPrice);

        position.collateralAmount+=collateralDelta;
        position.sizeInTokens+=indexTokenDelta;
        position.sizeInUSD+=sizeDelta;

        position.lastUpdatedAt = block.timestamp;

        if(position.sizeInUSD == 0 || position.sizeInTokens == 0 || position.collateralAmount == 0) revert("Empty Position");

        positions[msg.sender] = position;
        totalCollateral += collateralDelta;
        if(isLong) {
            OILong+=sizeDelta;
            OILongInTokens+=indexTokenDelta;
        }
        else {
            OIShort+=sizeDelta;
            OIShortInTokens+=indexTokenDelta;
        }

        _validateMaxUtil();
    }

    function _deposit(address caller, address receiver, uint256 assets, uint256 shares) internal override {
        super._deposit(caller, receiver, assets, shares);
        totalDeposits += assets;
    }

    function _withdraw(address caller, address receiver, address owner, uint256 assets, uint256 shares) internal override {
        totalDeposits -= assets;
        super._withdraw(caller, receiver, owner, assets, shares);
        _validateMaxUtil();
    }

    // Get real-time BTC price
    function getPrice() public view returns (uint256) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(btcPriceFeed);
        (, int256 price, , , ) = priceFeed.latestRoundData();
        require(price > 0, "Invalid price");
        uint256 _decimals = uint256(priceFeed.decimals());
        return priceNormalised(uint256(price),_decimals);
    }

    // Normalize Chainlink price (8 decimals) to 30 decimals
    function priceNormalised(uint256 price, uint256 decimals) public pure returns (uint256) {
        return price * 10 ** 14 ;
    }

    function _validateMaxUtil() internal {
        uint256 indexTokenPrice = getPrice();

        uint256 reservedShorts = OIShort;
        uint256 reservedLongs = OILongInTokens * indexTokenPrice;

        uint256 totalReserved = reservedLongs + reservedShorts;
        uint256 valueOfDeposits = totalDeposits;

        uint256 maxUtilizableValue = valueOfDeposits * maxUtilizationRatio / PRECISION ;

        if(totalReserved > maxUtilizableValue) revert("Max Utilization Breached");

    }
}