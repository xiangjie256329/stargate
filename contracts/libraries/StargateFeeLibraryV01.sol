// SPDX-License-Identifier: BUSL-1.1

pragma solidity 0.7.6;
pragma abicoder v2;
// 上面两行声明了 Solidity 编译器版本和 ABI 编码器版本

import "../interfaces/IStargateFeeLibrary.sol";
import "../Pool.sol";
import "../Factory.sol";

// libraries
import "@openzeppelin/contracts/math/SafeMath.sol";

// 定义合约，实现 IStargateFeeLibrary 接口，并继承 Ownable 和 ReentrancyGuard
contract StargateFeeLibraryV01 is IStargateFeeLibrary, Ownable, ReentrancyGuard {
    using SafeMath for uint256;

    uint256 public constant BP_DENOMINATOR = 10000;
    
    constructor(address _factory) {
        require(_factory != address(0x0), "FeeLibrary: Factory cannot be 0x0");
        factory = Factory(_factory);
    }
    
    //---------------------------------------------------------------------------
    // VARIABLES

    Factory public factory;
    
    // 定义四个公共变量，分别表示 LP 持有者费用、协议费用、平衡费用和平衡奖励费用的基点数值
    uint256 public lpFeeBP; // fee basis points for lp holders
    uint256 public protocolFeeBP; // fee basis points for xStargate
    uint256 public eqFeeBP; // fee basis points for eqFeeBP
    uint256 public eqRewardBP; // fee basis points for eqRewardBP

    //---------------------------------------------------------------------------
    // EVENTS

    // 定义一个事件，表示费用被更新了，并同时记录 LP 持有者费用和协议费用的基点数值
    event FeesUpdated(uint256 lpFeeBP, uint256 protocolFeeBP);

    // 定义一个名为 getFees 的函数，实现 IStargateFeeLibrary 接口中定义的函数 getFees。该函数接受五个参数，前三个不使用，
    // 第四个是 address 类型但不使用，第五个是 uint256 类型的交易数量。
    function getFees(
        uint256, /*_srcPoolId*/
        uint256, /*_dstPoolId*/
        uint16, /*_dstChainId*/
        address, /*_from*/
        uint256 _amountSD
    ) external view override returns (Pool.SwapObj memory s) {
        
        // calculate the xStargate Fee.
        // 计算协议费用 = 待提取资产的数量 * 协议费率 / 10000
        s.protocolFee = _amountSD.mul(protocolFeeBP).div(BP_DENOMINATOR);
        
        // calculate the LP fee. booked at remote
        // 计算 LP 持有者费用 = 待提取资产的数量 * lp持有者费率 / 10000
        s.lpFee = _amountSD.mul(lpFeeBP).div(BP_DENOMINATOR);

        // calculate the equilibrium Fee and reward
        // 计算平衡费用 = 待提取资产的数量 * 平衡费率 / 10000
        s.eqFee = _amountSD.mul(eqFeeBP).div(BP_DENOMINATOR);
        // 平衡奖励费率 = 待提取资产的数量 * 平衡奖励费率 / 10000
        s.eqReward = _amountSD.mul(eqRewardBP).div(BP_DENOMINATOR);
        
        return s;
    }

    // 定义一个名为 setFees 的函数，用于设置 LP 持有者费用、协议费用、平衡费用和平衡奖励费用的基点数值。该函数需要由合约拥有者调用。
    function setFees(
        uint256 _lpFeeBP,
        uint256 _protocolFeeBP,
        uint256 _eqFeeBP,
        uint256 _eqRewardBP
    ) external onlyOwner {
        // 要求输入的四个参数之和不能大于 BP_DENOMINATOR（即 10000）。否则抛出错误信息。
        require(_lpFeeBP.add(_protocolFeeBP).add(_eqFeeBP).add(_eqRewardBP) <= BP_DENOMINATOR, "FeeLibrary: sum fees > 100%");
        
        // 要求平衡奖励费用的基点数值不能大于平衡费用的基点数值。否则抛出错误信息。
        require(eqRewardBP <= eqFeeBP, "FeeLibrary: eq fee param incorrect");

        // 设置 LP 持有者费用、协议费用、平衡费用和平衡奖励费用的基点数值
        lpFeeBP = _lpFeeBP;
        protocolFeeBP = _protocolFeeBP;
        eqFeeBP = _eqFeeBP;
        eqRewardBP = _eqRewardBP;

        // 发布 FeesUpdated 事件，表示费用被更新了，并同时记录 LP 持有者费用和协议费用的基点数值
        emit FeesUpdated(lpFeeBP, protocolFeeBP);
    }

    function getVersion() external pure override returns (string memory) {
        return "1.0.0";
    }
}