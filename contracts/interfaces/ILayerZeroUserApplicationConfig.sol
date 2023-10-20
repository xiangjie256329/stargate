// SPDX-License-Identifier: BUSL-1.1

pragma solidity >=0.5.0;

interface ILayerZeroUserApplicationConfig {
    // @notice set the configuration of the LayerZero messaging library of the specified version
    // @param _version - messaging library version
    // @param _chainId - the chainId for the pending config change
    // @param _configType - type of configuration. every messaging library has its own convention.
    // @param _config - configuration in the bytes. can encode arbitrary content.

    // 设置指定版本的 LayerZero 消息库的配置。参数包括消息库版本 _version、待定配置更改的链标识符 _chainId、
    // 配置类型 _configType 和配置数据 _config
    function setConfig(uint16 _version, uint16 _chainId, uint _configType, bytes calldata _config) external;

    // @notice set the send() LayerZero messaging library version to _version
    // @param _version - new messaging library version
    // 将 send() 的 LayerZero 消息库版本设置为 _version
    function setSendVersion(uint16 _version) external;

    // @notice set the lzReceive() LayerZero messaging library version to _version
    // @param _version - new messaging library version
    // 将 lzReceive() 的 LayerZero 消息库版本设置为 _version
    function setReceiveVersion(uint16 _version) external;

    // @notice Only when the UA needs to resume the message flow in blocking mode and clear the stored payload
    // @param _srcChainId - the chainId of the source chain
    // @param _srcAddress - the contract address of the source contract at the source chain
    // 仅当用户应用需要在阻塞模式下恢复消息流并清除存储的负载时使用。参数包括源链的标识符 _srcChainId 和源链上合约的地址 _srcAddress
    function forceResumeReceive(uint16 _srcChainId, bytes calldata _srcAddress) external;
}
