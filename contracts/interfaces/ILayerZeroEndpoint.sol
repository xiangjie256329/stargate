// SPDX-License-Identifier: BUSL-1.1

pragma solidity >=0.5.0;

import "./ILayerZeroUserApplicationConfig.sol";

//这是一个Solidity智能合约接口，它定义了LayerZero的端点（Endpoint）应该实现的功能。LayerZero是一个跨链通信协议，
//支持通过EVM和非EVM（如Substrate、Solana等）区块链之间传输消息。Endpoint是LayerZero协议中的末端，负责发送和接收消息。
//该接口定义了消息发送、消息接收、获取费用估算、查询库地址、重试消息、查询是否存在存储的消息等方法。此外，还有一些方法用于版本控制，例如获取LayerZero消息库的版本号。
interface ILayerZeroEndpoint is ILayerZeroUserApplicationConfig {
    // @notice send a LayerZero message to the specified address at a LayerZero endpoint.
    // @param _dstChainId - the destination chain identifier
    // @param _destination - the address on destination chain (in bytes). address length/format may vary by chains
    // @param _payload - a custom bytes payload to send to the destination contract
    // @param _refundAddress - if the source transaction is cheaper than the amount of value passed, refund the additional amount to this address
    // @param _zroPaymentAddress - the address of the ZRO token holder who would pay for the transaction
    // @param _adapterParams - parameters for custom functionality. e.g. receive airdropped native gas from the relayer on destination

    // 发送一个 LayerZero 消息到指定的 LayerZero 端点。参数包括目标链的标识符 _dstChainId、目标地址 _destination、自定义负载 _payload、
    // 退款地址 _refundAddress、支付交易费用的 ZRO 代币持有者地址 _zroPaymentAddress 和适配器参数 _adapterParams。
    function send(uint16 _dstChainId, bytes calldata _destination, bytes calldata _payload, address payable _refundAddress, address _zroPaymentAddress, bytes calldata _adapterParams) external payable;

    // @notice used by the messaging library to publish verified payload
    // @param _srcChainId - the source chain identifier
    // @param _srcAddress - the source contract (as bytes) at the source chain
    // @param _dstAddress - the address on destination chain
    // @param _nonce - the unbound message ordering nonce
    // @param _gasLimit - the gas limit for external contract execution
    // @param _payload - verified payload to send to the destination contract
    
    //由消息库用于发布验证的负载。参数包括源链的标识符 _srcChainId、源链上的源合约地址 _srcAddress、目标链上的地址 _dstAddress、
    //未绑定消息排序的 nonce _nonce、外部合约执行的 gas 限制 _gasLimit 和验证的负载 _payload
    function receivePayload(uint16 _srcChainId, bytes calldata _srcAddress, address _dstAddress, uint64 _nonce, uint _gasLimit, bytes calldata _payload) external;

    // @notice get the inboundNonce of a receiver from a source chain which could be EVM or non-EVM chain
    // @param _srcChainId - the source chain identifier
    // @param _srcAddress - the source chain contract address

    //根据源链的标识符 _srcChainId 和源链上的合约地址 _srcAddress 获取接收者的入站 nonce
    function getInboundNonce(uint16 _srcChainId, bytes calldata _srcAddress) external view returns (uint64);

    // @notice get the outboundNonce from this source chain which, consequently, is always an EVM
    // @param _srcAddress - the source chain contract address
    // 根据目标链的标识符 _dstChainId 和源链上的合约地址 _srcAddress 获取该源链的出站 nonce
    function getOutboundNonce(uint16 _dstChainId, address _srcAddress) external view returns (uint64);

    // @notice gets a quote in source native gas, for the amount that send() requires to pay for message delivery
    // @param _dstChainId - the destination chain identifier
    // @param _userApplication - the user app address on this EVM chain
    // @param _payload - the custom message to send over LayerZero
    // @param _payInZRO - if false, user app pays the protocol fee in native token
    // @param _adapterParam - parameters for the adapter service, e.g. send some dust native token to dstChain
    // 获取发送 send() 函数所需支付的原生 gas 数量的估计值。参数包括目标链的标识符 _dstChainId、此 EVM 链上用户应用的地址 _userApplication、
    // 要发送到 LayerZero 的自定义消息 _payload、是否使用 ZRO 代币支付协议费用 _payInZRO 和适配器参数 _adapterParam。返回值为原生费用和 ZRO 费用
    function estimateFees(uint16 _dstChainId, address _userApplication, bytes calldata _payload, bool _payInZRO, bytes calldata _adapterParam) external view returns (uint nativeFee, uint zroFee);

    // @notice get this Endpoint's immutable source identifier
    function getChainId() external view returns (uint16);

    // @notice the interface to retry failed message on this Endpoint destination
    // @param _srcChainId - the source chain identifier
    // @param _srcAddress - the source chain contract address
    // @param _payload - the payload to be retried

    // 在此端点的目标上重试失败的消息。参数包括源链的标识符 _srcChainId、源链上的合约地址 _srcAddress 和要重试的负载 _payload
    function retryPayload(uint16 _srcChainId, bytes calldata _srcAddress, bytes calldata _payload) external;

    // @notice query if any STORED payload (message blocking) at the endpoint.
    // @param _srcChainId - the source chain identifier
    // @param _srcAddress - the source chain contract address

    // 查询端点是否存储了任何已阻塞的负载（消息）。参数包括源链的标识符 _srcChainId 和源链上的合约地址 _srcAddress
    function hasStoredPayload(uint16 _srcChainId, bytes calldata _srcAddress) external view returns (bool);

    // @notice query if the _libraryAddress is valid for sending msgs.
    // @param _userApplication - the user app address on this EVM chain

    // 查询 _userApplication 是否有效用于发送消息
    function getSendLibraryAddress(address _userApplication) external view returns (address);

    // @notice query if the _libraryAddress is valid for receiving msgs.
    // @param _userApplication - the user app address on this EVM chain

    // 查询 _userApplication 是否有效用于接收消息
    function getReceiveLibraryAddress(address _userApplication) external view returns (address);

    // @notice query if the non-reentrancy guard for send() is on
    // @return true if the guard is on. false otherwise

    // 查询 send() 的非重入保护是否开启
    function isSendingPayload() external view returns (bool);

    // @notice query if the non-reentrancy guard for receive() is on
    // @return true if the guard is on. false otherwise

    // 查询 receive() 的非重入保护是否开启
    function isReceivingPayload() external view returns (bool);

    // @notice get the configuration of the LayerZero messaging library of the specified version
    // @param _version - messaging library version
    // @param _chainId - the chainId for the pending config change
    // @param _userApplication - the contract address of the user application
    // @param _configType - type of configuration. every messaging library has its own convention.

    // 获取指定版本的 LayerZero 消息库的配置。参数包括消息库版本 _version、待定配置更改的链标识符 _chainId、
    // 用户应用的合约地址 _userApplication 和配置类型 _configType。返回值为配置数据
    function getConfig(uint16 _version, uint16 _chainId, address _userApplication, uint _configType) external view returns (bytes memory);

    // @notice get the send() LayerZero messaging library version
    // @param _userApplication - the contract address of the user application

    // 获取 send() 的 LayerZero 消息库版本。参数为用户应用的合约地址 _userApplication
    function getSendVersion(address _userApplication) external view returns (uint16);

    // @notice get the lzReceive() LayerZero messaging library version
    // @param _userApplication - the contract address of the user application

    //获取 lzReceive() 的 LayerZero 消息库版本。参数为用户应用的合约地址 _userApplication
    function getReceiveVersion(address _userApplication) external view returns (uint16);
}
