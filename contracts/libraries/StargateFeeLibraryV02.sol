// SPDX-License-Identifier: BUSL-1.1

pragma solidity 0.7.6;
pragma abicoder v2;

import "../interfaces/IStargateFeeLibrary.sol";
import "../Pool.sol";
import "../Factory.sol";

import "@openzeppelin/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract StargateFeeLibraryV02 is IStargateFeeLibrary, Ownable, ReentrancyGuard {
    using SafeMath for uint256;

    //---------------------------------------------------------------------------
    // VARIABLES
    
    // 平衡函数参数，单位为BP * 10 ^ 2，即1% = 10 ^ 6单位
    uint256 public constant DENOMINATOR = 1e18;
    uint256 public constant DELTA_1 = 6000 * 1e14;
    uint256 public constant DELTA_2 = 500 * 1e14;
    uint256 public constant LAMBDA_1 = 40 * 1e14;
    uint256 public constant LAMBDA_2 = 9960 * 1e14;
    uint256 public constant LP_FEE = 45 * 1e13;
    uint256 public constant PROTOCOL_FEE = 15 * 1e13;
    uint256 public constant PROTOCOL_SUBSIDY = 3 * 1e13;

    Factory public immutable factory;

    constructor(address _factory) {
        require(_factory != address(0x0), "FeeLibrary: Factory cannot be 0x0");
        factory = Factory(_factory);
    }

    /**
    * @dev 获取手续费信息
    * @param _srcPoolId 源池子ID
    * @param _dstPoolId 目标池子ID
    * @param _dstChainId 目标链ID
    * @param _amountSD 交易金额（源池子币种的数量）
    * @return s 手续费信息结构体
    */
    function getFees(
        uint256 _srcPoolId,
        uint256 _dstPoolId,
        uint16 _dstChainId,
        address, /*_from*/
        uint256 _amountSD
    ) external view override returns (Pool.SwapObj memory s) {
        
        // 计算协议手续费 = 待提取资产的数量 * (15 * 1e13) / 1e18
        s.protocolFee = _amountSD.mul(PROTOCOL_FEE).div(DENOMINATOR);

        // 计算平衡手续费
        Pool pool = factory.getPool(_srcPoolId);
        // 获取目标链路
        Pool.ChainPath memory chainPath = pool.getChainPath(_dstChainId, _dstPoolId);

        // 计算平衡手续费
        (uint256 eqFee, uint256 protocolSubsidy) = _getEquilibriumFee(chainPath.idealBalance, chainPath.balance, _amountSD);
        s.eqFee = eqFee;
        s.protocolFee = s.protocolFee.sub(protocolSubsidy);

        // 计算平衡奖励
        address tokenAddress = pool.token();
        uint256 currentAssetSD = IERC20(tokenAddress).balanceOf(address(pool)).div(pool.convertRate());
        uint256 lpAsset = pool.totalLiquidity();
        if (lpAsset > currentAssetSD) {
            // 资产不足
            uint256 poolDeficit = lpAsset.sub(currentAssetSD);
            uint256 rewardPoolSize = pool.eqFeePool();
            // 奖励上限为rewardPoolSize
            uint256 eqRewards = rewardPoolSize.mul(_amountSD).div(poolDeficit);
            if (eqRewards > rewardPoolSize) {
                eqRewards = rewardPoolSize;
            }
            s.eqReward = eqRewards;
        }

        // 计算LP手续费
        s.lpFee = _amountSD.mul(LP_FEE).div(DENOMINATOR);

        return s;
    }

    /**
    * @dev 获取平衡手续费和协议补贴
    * @param idealBalance 理想余额
    * @param beforeBalance 交易前余额
    * @param amountSD 交易金额（源池子币种的数量）
    * @return eqFee 平衡手续费
    * @return protocolSubsidy 协议补贴
    */
    function getEquilibriumFee(
        uint256 idealBalance,
        uint256 beforeBalance,
        uint256 amountSD
    ) external pure returns (uint256, uint256) {
        return _getEquilibriumFee(idealBalance, beforeBalance, amountSD);
    }

    /**
    * @dev 获取梯形面积
    * @param lambda 参数lambda
    * @param yOffset y轴偏移量
    * @param xUpperBound 上界x坐标
    * @param xLowerBound 下界x坐标
    * @param xStart 起始x坐标
    * @param xEnd 结束x坐标
    * @return 梯形面积
    */
    function getTrapezoidArea(
        uint256 lambda,
        uint256 yOffset,
        uint256 xUpperBound,
        uint256 xLowerBound,
        uint256 xStart,
        uint256 xEnd
    ) external pure returns (uint256) {
        return _getTrapezoidArea(lambda, yOffset, xUpperBound, xLowerBound, xStart, xEnd);
    }

    /**
    * @dev 获取平衡手续费和协议补贴内部函数
    * @param idealBalance 理想余额
    * @param beforeBalance 交易前余额
    * @param amountSD 交易金额（源池子币种的数量）
    * @return eqFee 平衡手续费
    * @return protocolSubsidy 协议补贴
    */
    function _getEquilibriumFee(
        uint256 idealBalance,
        uint256 beforeBalance,
        uint256 amountSD
    ) internal pure returns (uint256, uint256) {
        require(beforeBalance >= amountSD, "Stargate: not enough balance");
        uint256 afterBalance = beforeBalance.sub(amountSD);

        // idealBalance * 6000 * 1e14 / 1e18; 60/100
        uint256 safeZoneMax = idealBalance.mul(DELTA_1).div(DENOMINATOR);
        // idealBalance * 500 * 1e14 / 1e18; 5/100
        uint256 safeZoneMin = idealBalance.mul(DELTA_2).div(DENOMINATOR);

        uint256 eqFee = 0;
        uint256 protocolSubsidy = 0;

        //剩余金额 > 理想余额 * 60/100
        if (afterBalance >= safeZoneMax) {
            // 无手续费区域，协议补贴
            // eqFee = amountSD * 3 * 1e13 / 1e18
            eqFee = amountSD.mul(PROTOCOL_SUBSIDY).div(DENOMINATOR);
            protocolSubsidy = eqFee;
        } else if (afterBalance >= safeZoneMin) { //剩余金额 > 理想余额 * 5/100
            // 安全区域
            uint256 proxyBeforeBalance = beforeBalance < safeZoneMax ? beforeBalance : safeZoneMax;
            eqFee = _getTrapezoidArea(LAMBDA_1, 0, safeZoneMax, safeZoneMin, proxyBeforeBalance, afterBalance);
        } else {
            //剩余金额小于理想金额的5%
            //交易前余额 >= 理想金额的5%
            if (beforeBalance >= safeZoneMin) {
                // 跨越2或3个区域
                // 第一部分
                uint256 proxyBeforeBalance = beforeBalance < safeZoneMax ? beforeBalance : safeZoneMax;
                eqFee = eqFee.add(_getTrapezoidArea(LAMBDA_1, 0, safeZoneMax, safeZoneMin, proxyBeforeBalance, safeZoneMin));
                // 第二部分
                eqFee = eqFee.add(_getTrapezoidArea(LAMBDA_2, LAMBDA_1, safeZoneMin, 0, safeZoneMin, afterBalance));
            } else {
                // 只在危险区域
                // 只计算第二部分
                eqFee = eqFee.add(_getTrapezoidArea(LAMBDA_2, LAMBDA_1, safeZoneMin, 0, beforeBalance, afterBalance));
            }
        }
        return (eqFee, protocolSubsidy);
    }

    /**
    * @dev 获取梯形面积内部函数
    * @param lambda 参数lambda
    * @param yOffset y轴偏移量
    * @param xUpperBound 上界x坐标
    * @param xLowerBound 下界x坐标
    * @param xStart 起始x坐标
    * @param xEnd 结束x坐标
    * @return 梯形面积
    */
    function _getTrapezoidArea(
        uint256 lambda,
        uint256 yOffset,
        uint256 xUpperBound,
        uint256 xLowerBound,
        uint256 xStart,
        uint256 xEnd
    ) internal pure returns (uint256) {
        require(xEnd >= xLowerBound && xStart <= xUpperBound, "Stargate: balance out of bound");
        uint256 xBoundWidth = xUpperBound.sub(xLowerBound);

        // xStartDrift = xUpperBound.sub(xStart);
        uint256 yStart = xUpperBound.sub(xStart).mul(lambda).div(xBoundWidth).add(yOffset);

        // xEndDrift = xUpperBound.sub(xEnd)
        uint256 yEnd = xUpperBound.sub(xEnd).mul(lambda).div(xBoundWidth).add(yOffset);

        // 计算面积
        uint256 deltaX = xStart.sub(xEnd);
        return yStart.add(yEnd).mul(deltaX).div(2).div(DENOMINATOR);
    }

    /**
    * @dev 获取版本号
    * @return 版本号
    */
    function getVersion() external pure override returns (string memory) {
        return "2.0.0";
    }
}
