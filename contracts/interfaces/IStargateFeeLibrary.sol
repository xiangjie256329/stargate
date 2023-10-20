// SPDX-License-Identifier: BUSL-1.1

pragma solidity ^0.7.6;
pragma abicoder v2;
import "../Pool.sol";

interface IStargateFeeLibrary {
    //据参数 _srcPoolId、_dstPoolId、_dstChainId、_from 和 _amountSD 获取费用信息，并返回一个 Pool.SwapObj 结构体。该函数是外部可调用的
    function getFees(
        uint256 _srcPoolId,
        uint256 _dstPoolId,
        uint16 _dstChainId,
        address _from,
        uint256 _amountSD
    ) external returns (Pool.SwapObj memory s);

    function getVersion() external view returns (string memory);
}
