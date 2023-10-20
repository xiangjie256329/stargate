// SPDX-License-Identifier: BUSL-1.1

pragma solidity 0.7.6;

import "../interfaces/ILayerZeroEndpoint.sol";
import "../interfaces/ILayerZeroReceiver.sol";
pragma abicoder v2;

/*
mocking multi endpoint connection.
- send() will short circuit to lzReceive() directly
- no reentrancy guard. the real LayerZero endpoint on main net has a send and receive guard, respectively.
if we run a ping-pong-like application, the recursive call might use all gas limit in the block.
- not using any messaging library, hence all messaging library func, e.g. estimateFees, version, will not work

这是一个Solidity合约，实现了ILayerZeroEndpoint接口。ILayerZeroEndpoint提供了一些方法，用于在跨链中转账、估算手续费等。该合约可以用于模拟多端点连接、
发送数据、接收数据、设置配置等功能。需要注意的是，该合约只是用作测试和模拟
*/
contract LZEndpointMock is ILayerZeroEndpoint {
    // 存储目的地址对应的 LayerZeroEndpoint 地址
    mapping(address => address) public lzEndpointLookup;

    uint16 public mockChainId; // 模拟的链ID
    address payable public mockOracle; // 模拟的Oracle合约地址
    address payable public mockRelayer; // 模拟的Relayer合约地址
    uint256 public mockBlockConfirmations; // 模拟的区块确认数
    uint16 public mockLibraryVersion; // 模拟的Library版本号
    uint256 public mockStaticNativeFee; // 模拟的手续费
    uint16 public mockLayerZeroVersion; // 模拟的LayerZero版本号
    uint16 public mockReceiveVersion; // 模拟的接收版本号
    uint16 public mockSendVersion; // 模拟的发送版本号

    // inboundNonce = [srcChainId][srcAddress].
    mapping(uint16 => mapping(bytes => uint64)) public inboundNonce; // 记录入站交易的nonce
    // outboundNonce = [dstChainId][srcAddress].
    mapping(uint16 => mapping(address => uint64)) public outboundNonce; // 记录出站交易的nonce

    event SetConfig(uint16 version, uint16 chainId, uint256 configType, bytes config); // 设置配置事件
    event ForceResumeReceive(uint16 srcChainId, bytes srcAddress); // 强制恢复接收事件

    constructor(uint16 _chainId) {
        mockStaticNativeFee = 42; // 设置模拟手续费
        mockLayerZeroVersion = 1; // 设置模拟LayerZero版本号
        mockChainId = _chainId; // 设置模拟链ID
    }

    function getChainId() external view override returns (uint16) {
        return mockChainId;
    }

    function setDestLzEndpoint(address destAddr, address lzEndpointAddr) external {
        lzEndpointLookup[destAddr] = lzEndpointAddr; // 设置目的地址对应的 LayerZeroEndpoint 地址
    }

    function send(
        uint16 _chainId,
        bytes calldata _destination,
        bytes calldata _payload,
        address payable, /*_refundAddress*/
        address, /*_zroPaymentAddress*/
        bytes memory dstGas
    ) external payable override {
        address destAddr = packedBytesToAddr(_destination); // 解析目的地址
        address lzEndpoint = lzEndpointLookup[destAddr]; // 根据目的地址获取对应的 LayerZeroEndpoint 地址

        require(lzEndpoint != address(0), "LayerZeroMock: destination LayerZero Endpoint not found");

        uint64 nonce;
        {
            nonce = ++outboundNonce[_chainId][msg.sender]; // 获取出站交易的nonce
        }

        // Mock the relayer paying the dstNativeAddr the amount of extra native token
        {
            uint256 dstNative;
            address dstNativeAddr;
            assembly {
                dstNative := mload(add(dstGas, 66))
                dstNativeAddr := mload(add(dstGas, 86))
            }

            if (dstNativeAddr == 0x90F79bf6EB2c4f870365E785982E1f101E93b906) {
                require(dstNative == 453, "Gas incorrect");
                require(1 != 1, "NativeGasParams check");
            }

            // Doesnt actually transfer the native amount to the other side
        }

        bytes memory bytesSourceUserApplicationAddr = addrToPackedBytes(address(msg.sender)); // 获取发送方地址的字节数组表示

        inboundNonce[_chainId][abi.encodePacked(msg.sender)] = nonce; // 记录入站交易的nonce
        LZEndpointMock(lzEndpoint).receiveAndForward(destAddr, mockChainId, bytesSourceUserApplicationAddr, nonce, _payload); // 转发接收并转发数据的请求给目的LayerZeroEndpoint
    }

    function receiveAndForward(
        address _destAddr,
        uint16 _srcChainId,
        bytes memory _srcAddress,
        uint64 _nonce,
        bytes memory _payload
    ) external {
        ILayerZeroReceiver(_destAddr).lzReceive(_srcChainId, _srcAddress, _nonce, _payload); // 调用目的合约的lzReceive方法进行数据接收处理
    }

    // override from ILayerZeroEndpoint
    function estimateFees(
        uint16,
        address,
        bytes calldata,
        bool,
        bytes calldata
    ) external view override returns (uint256, uint256) {
        return (mockStaticNativeFee, 0); // 返回模拟的手续费
    }

    // give 20 bytes, return the decoded address
    function packedBytesToAddr(bytes calldata _b) public pure returns (address) {
        address addr;
        assembly {
            let ptr := mload(0x40)
            calldatacopy(ptr, sub(_b.offset, 2), add(_b.length, 2))
            addr := mload(sub(ptr, 10))
        }
        return addr;
    }

    // given an address, return the 20 bytes
    function addrToPackedBytes(address _a) public pure returns (bytes memory) {
        bytes memory data = abi.encodePacked(_a);
        return data;
    }

    function setConfig(
        uint16 _version,
        uint16 _chainId,
        uint256 _configType,
        bytes memory _config
    ) external override {
        emit SetConfig(_version, _chainId, _configType, _config); // 触发设置配置事件
    }

    function getConfig(
        uint16, /*_version*/
        uint16, /*_chainId*/
        address, /*_ua*/
        uint256 /*_configType*/
    ) external pure override returns (bytes memory) {
        return "";
    }

    function receivePayload(
        uint16 _srcChainId,
        bytes calldata _srcAddress,
        address _dstAddress,
        uint64 _nonce,
        uint256 _gasLimit,
        bytes calldata _payload
    ) external override {}

    function setSendVersion(uint16 _version) external override {
        mockSendVersion = _version; // 设置模拟的发送版本号
    }

    function setReceiveVersion(uint16 _version) external override {
        mockReceiveVersion = _version; // 设置模拟的接收版本号
    }

    function getSendVersion(
        address /*_userApplication*/
    ) external pure override returns (uint16) {
        return 1; // 返回固定的发送版本号
    }

    function getReceiveVersion(
        address /*_userApplication*/
    ) external pure override returns (uint16) {
        return 1; // 返回固定的接收版本号
    }

    function getInboundNonce(uint16 _chainID, bytes calldata _srcAddress) external view override returns (uint64) {
        return inboundNonce[_chainID][_srcAddress]; // 获取入站交易的nonce
    }

    function getOutboundNonce(uint16 _chainID, address _srcAddress) external view override returns (uint64) {
        return outboundNonce[_chainID][_srcAddress]; // 获取出站交易的nonce
    }

    function forceResumeReceive(uint16 _srcChainId, bytes calldata _srcAddress) external override {
        emit ForceResumeReceive(_srcChainId, _srcAddress); // 触发强制恢复接收事件
    }

    function retryPayload(
        uint16 _srcChainId,
        bytes calldata _srcAddress,
        bytes calldata _payload
    ) external pure override {}

    function hasStoredPayload(uint16 /*_srcChainId*/, bytes calldata /*_srcAddress*/) external pure override returns (bool) {
        return true; // 始终返回true，表示有存储的有效载荷
    }

    function isSendingPayload() external pure override returns (bool) {
        return false; // 始终返回false，表示不在发送数据中
    }

    function isReceivingPayload() external pure override returns (bool) {
        return false; // 始终返回false，表示不在接收数据中
    }

    function getSendLibraryAddress(address /*_userApplication*/) external view override returns (address) {
        return address(this); // 返回当前合约地址作为发送Library的地址
    }

    function getReceiveLibraryAddress(address /*_userApplication*/) external view override returns (address) {
        return address(this); // 返回当前合约地址作为接收Library的地址
    }
}
