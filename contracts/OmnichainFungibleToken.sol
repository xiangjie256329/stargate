// SPDX-License-Identifier: BUSL-1.1

pragma solidity 0.7.6;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "./interfaces/ILayerZeroReceiver.sol";
import "./interfaces/ILayerZeroEndpoint.sol";
import "./interfaces/ILayerZeroUserApplicationConfig.sol";

//---------------------------------------------------------------------------
// THIS CONTRACT IS OF BUSINESS LICENSE. CONTACT US BEFORE YOU USE IT.
//
// LayerZero is pushing now a new cross-chain token standard with permissive license soon
//
// Stay tuned for maximum cross-chain compatability of your token
//---------------------------------------------------------------------------
// 这是一个名为OmnichainFungibleToken的智能合约，它实现了ERC20、Ownable、ILayerZeroReceiver和
// ILayerZeroUserApplicationConfig等接口。该智能合约用于跨链转账，并具有暂停和恢复功能。
contract OmnichainFungibleToken is ERC20, Ownable, ILayerZeroReceiver, ILayerZeroUserApplicationConfig {
    ILayerZeroEndpoint immutable public endpoint;
    mapping(uint16 => bytes) public dstContractLookup; // 目标链的合约地址映射
    bool public paused; // 表示跨链转账是否暂停
    bool public isMain; // 表示该合约是否在主链上

    event Paused(bool isPaused);
    event SendToChain(uint16 srcChainId, bytes toAddress, uint256 qty, uint64 nonce);
    event ReceiveFromChain(uint16 srcChainId, address toAddress, uint256 qty, uint64 nonce);

    constructor(
        string memory _name,
        string memory _symbol,
        address _endpoint,
        uint16 _mainChainId,
        uint256 _initialSupplyOnMainEndpoint
    ) ERC20(_name, _symbol) {
        // 只在主链上铸造总供应量
        if (ILayerZeroEndpoint(_endpoint).getChainId() == _mainChainId) {
            _mint(msg.sender, _initialSupplyOnMainEndpoint);
            isMain = true;
        }
        // 设置 LayerZero 端点地址
        endpoint = ILayerZeroEndpoint(_endpoint);
    }

    function pauseSendTokens(bool _pause) external onlyOwner {
        paused = _pause; // 暂停/恢复跨链转账
        emit Paused(_pause);
    }

    function setDestination(uint16 _dstChainId, bytes calldata _destinationContractAddress) public onlyOwner {
        dstContractLookup[_dstChainId] = _destinationContractAddress; // 设置目标链的合约地址
    }

    function chainId() external view returns (uint16){
        return endpoint.getChainId(); // 获取链的ID
    }

    function sendTokens(
        uint16 _dstChainId, // 发送代币到该链ID
        bytes calldata _to, // 在目标链上投递代币的地址
        uint256 _qty, // 发送的代币数量
        address _zroPaymentAddress, // ZRO 支付地址
        bytes calldata _adapterParam // 交易参数
    ) public payable {
        require(!paused, "OFT: sendTokens() is currently paused");

        // 如果在主链上，则通过转账到合约进行锁定，否则销毁
        if (isMain) {
            _transfer(msg.sender, address(this), _qty);
        } else {
            _burn(msg.sender, _qty);
        }

        // 使用 abi.encode() 对要发送的值进行编码
        bytes memory payload = abi.encode(_to, _qty);

        // 发送 LayerZero 消息
        endpoint.send{value: msg.value}(
            _dstChainId, // 目标链ID
            dstContractLookup[_dstChainId], // 目标 UA 地址
            payload, // 编码的字节数组
            msg.sender, // 退款地址（LayerZero 将把多余的手续费退还给该地址）
            _zroPaymentAddress, // 'zroPaymentAddress'
            _adapterParam // 'adapterParameters'
        );
        uint64 nonce = endpoint.getOutboundNonce(_dstChainId, address(this));
        emit SendToChain(_dstChainId, _to, _qty, nonce);
    }

    function lzReceive(
        uint16 _srcChainId,
        bytes memory _fromAddress,
        uint64 _nonce,
        bytes memory _payload
    ) external override {
        require(msg.sender == address(endpoint)); // 只能由端点调用 lzReceive
        require(
            _fromAddress.length == dstContractLookup[_srcChainId].length && keccak256(_fromAddress) == keccak256(dstContractLookup[_srcChainId]),
            "OFT: invalid source sending contract"
        );

        // 解码并加载 to 地址
        (bytes memory _to, uint256 _qty) = abi.decode(_payload, (bytes, uint256));
        address toAddress;
        assembly { toAddress := mload(add(_to, 20)) }

        // 如果 to 地址是 0x0，则销毁代币
        if (toAddress == address(0x0)) toAddress == address(0xdEaD);

        // 在主链上通过转账解锁代币，否则铸造代币
        if (isMain) {
            _transfer(address(this), toAddress, _qty);
        } else {
            _mint(toAddress, _qty);
        }

        emit ReceiveFromChain(_srcChainId, toAddress, _qty, _nonce);
    }

    function estimateSendTokensFee(uint16 _dstChainId, bytes calldata _toAddress, bool _useZro, bytes calldata _txParameters) external view returns (uint256 nativeFee, uint256 zroFee) {
        // 模拟 sendTokens() 的 payload
        bytes memory payload = abi.encode(_toAddress, 1);
        return endpoint.estimateFees(_dstChainId, address(this), payload, _useZro, _txParameters);
    }

    //---------------------------DAO CALL----------------------------------------
    // 用户应用的通用配置
    function setConfig(
        uint16 _version,
        uint16 _chainId,
        uint256 _configType,
        bytes calldata _config
    ) external override onlyOwner {
        endpoint.setConfig(_version, _chainId, _configType, _config); // 设置用户应用的配置
    }

    function setSendVersion(uint16 _version) external override onlyOwner {
        endpoint.setSendVersion(_version); // 设置发送版本
    }

    function setReceiveVersion(uint16 _version) external override onlyOwner {
        endpoint.setReceiveVersion(_version); // 设置接收版本
    }

    function forceResumeReceive(uint16 _srcChainId, bytes calldata _srcAddress) external override onlyOwner {
        endpoint.forceResumeReceive(_srcChainId, _srcAddress); // 强制恢复接收
    }

    function renounceOwnership() public override onlyOwner {}
}
