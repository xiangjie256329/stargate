// SPDX-License-Identifier: BUSL-1.1

pragma solidity 0.7.6;
pragma abicoder v2;

// imports
import "@openzeppelin/contracts/access/Ownable.sol"; // 导入 openzeppelin 库中的 Ownable 合约

import "./Pool.sol"; // 导入自定义合约 Pool.sol
import "./Router.sol"; // 导入自定义合约 Router.sol

// libraries
import "@openzeppelin/contracts/math/SafeMath.sol"; // 导入 openzeppelin 库中的 SafeMath 库
import "./interfaces/ILayerZeroReceiver.sol"; // 导入自定义接口 ILayerZeroReceiver
import "./interfaces/ILayerZeroEndpoint.sol"; // 导入自定义接口 ILayerZeroEndpoint
import "./interfaces/ILayerZeroUserApplicationConfig.sol"; // 导入自定义接口 ILayerZeroUserApplicationConfig

contract Bridge is Ownable, ILayerZeroReceiver, ILayerZeroUserApplicationConfig {
    using SafeMath for uint256; // 使用 SafeMath 库中的安全数学运算函数

    //---------------------------------------------------------------------------
    // CONSTANTS（常量）
    uint8 internal constant TYPE_SWAP_REMOTE = 1; // 远程交换类型
    uint8 internal constant TYPE_ADD_LIQUIDITY = 2; // 添加流动性类型
    uint8 internal constant TYPE_REDEEM_LOCAL_CALL_BACK = 3; // 本地回调赎回类型
    uint8 internal constant TYPE_WITHDRAW_REMOTE = 4; // 远程提取类型

    //---------------------------------------------------------------------------
    // VARIABLES（变量）
    ILayerZeroEndpoint public immutable layerZeroEndpoint; // 不可变的 LayerZeroEndpoint 实例
    mapping(uint16 => bytes) public bridgeLookup; // 桥接查询映射表，用于验证桥接是否匹配
    mapping(uint16 => mapping(uint8 => uint256)) public gasLookup; // 燃气查询映射表，用于存储燃气费

    Router public immutable router; // 不可变的 Router 实例
    bool public useLayerZeroToken; // 是否使用 LayerZero 代币

    //---------------------------------------------------------------------------
    // EVENTS（事件）
    event SendMsg(uint8 msgType, uint64 nonce); // 发送消息事件

    //---------------------------------------------------------------------------
    // MODIFIERS（修饰器）
    modifier onlyRouter() {
        require(msg.sender == address(router), "Stargate: caller must be Router."); // 限制只能由 Router 合约调用
        _;
    }

    constructor(address _layerZeroEndpoint, address _router) {
        require(_layerZeroEndpoint != address(0x0), "Stargate: _layerZeroEndpoint cannot be 0x0"); // 确保 _layerZeroEndpoint 地址不为0
        require(_router != address(0x0), "Stargate: _router cannot be 0x0"); // 确保 _router 地址不为0

        layerZeroEndpoint = ILayerZeroEndpoint(_layerZeroEndpoint); // 初始化 layerZeroEndpoint 实例
        router = Router(_router); // 初始化 router 实例
    }

    //---------------------------------------------------------------------------
    // EXTERNAL FUNCTIONS（外部函数）

    // 外部函数，用于接收来自 LayerZero 的消息
    function lzReceive(
        uint16 _srcChainId,
        bytes memory _srcAddress,
        uint64 _nonce,
        bytes memory _payload
    ) external override {
        require(msg.sender == address(layerZeroEndpoint), "Stargate: only LayerZero endpoint can call lzReceive"); // 限制只能由 layerZeroEndpoint 合约调用
        require(
            _srcAddress.length == bridgeLookup[_srcChainId].length && keccak256(_srcAddress) == keccak256(bridgeLookup[_srcChainId]),
            "Stargate: bridge does not match" // 确保桥接地址匹配
        );

        uint8 functionType;
        assembly {
            functionType := mload(add(_payload, 32))
        }

        if (functionType == TYPE_SWAP_REMOTE) {
            (
                ,
                uint256 srcPoolId,
                uint256 dstPoolId,
                uint256 dstGasForCall,
                Pool.CreditObj memory c,
                Pool.SwapObj memory s,
                bytes memory to,
                bytes memory payload
            ) = abi.decode(_payload, (uint8, uint256, uint256, uint256, Pool.CreditObj, Pool.SwapObj, bytes, bytes));
            address toAddress;
            assembly {
                toAddress := mload(add(to, 20))
            }
            router.creditChainPath(_srcChainId, srcPoolId, dstPoolId, c);
            router.swapRemote(_srcChainId, _srcAddress, _nonce, srcPoolId, dstPoolId, dstGasForCall, toAddress, s, payload);
        } else if (functionType == TYPE_ADD_LIQUIDITY) {
            (, uint256 srcPoolId, uint256 dstPoolId, Pool.CreditObj memory c) = abi.decode(_payload, (uint8, uint256, uint256, Pool.CreditObj));
            router.creditChainPath(_srcChainId, srcPoolId, dstPoolId, c);
        } else if (functionType == TYPE_REDEEM_LOCAL_CALL_BACK) {
            (, uint256 srcPoolId, uint256 dstPoolId, Pool.CreditObj memory c, uint256 amountSD, uint256 mintAmountSD, bytes memory to) = abi
                .decode(_payload, (uint8, uint256, uint256, Pool.CreditObj, uint256, uint256, bytes));
            address toAddress;
            assembly {
                toAddress := mload(add(to, 20))
            }
            router.creditChainPath(_srcChainId, srcPoolId, dstPoolId, c);
            router.redeemLocalCallback(_srcChainId, _srcAddress, _nonce, srcPoolId, dstPoolId, toAddress, amountSD, mintAmountSD);
        } else if (functionType == TYPE_WITHDRAW_REMOTE) {
            (, uint256 srcPoolId, uint256 dstPoolId, Pool.CreditObj memory c, uint256 amountSD, bytes memory to) = abi.decode(
                _payload,
                (uint8, uint256, uint256, Pool.CreditObj, uint256, bytes)
            );
            router.creditChainPath(_srcChainId, srcPoolId, dstPoolId, c);
            router.redeemLocalCheckOnRemote(_srcChainId, _srcAddress, _nonce, srcPoolId, dstPoolId, amountSD, to);
        }
    }

    //---------------------------------------------------------------------------
    // LOCAL CHAIN FUNCTIONS（本地链函数）

    // 进行交换操作
    function swap(
        uint16 _chainId,
        uint256 _srcPoolId,
        uint256 _dstPoolId,
        address payable _refundAddress,
        Pool.CreditObj memory _c,
        Pool.SwapObj memory _s,
        IStargateRouter.lzTxObj memory _lzTxParams,
        bytes calldata _to,
        bytes calldata _payload
    ) external payable onlyRouter {
        bytes memory payload = abi.encode(TYPE_SWAP_REMOTE, _srcPoolId, _dstPoolId, _lzTxParams.dstGasForCall, _c, _s, _to, _payload);
        _call(_chainId, TYPE_SWAP_REMOTE, _refundAddress, _lzTxParams, payload);
    }

    // 本地链回调赎回操作
    function redeemLocalCallback(
        uint16 _chainId,
        address payable _refundAddress,
        Pool.CreditObj memory _c,
        IStargateRouter.lzTxObj memory _lzTxParams,
        bytes memory _payload
    ) external payable onlyRouter {
        bytes memory payload;

        {
            (, uint256 srcPoolId, uint256 dstPoolId, uint256 amountSD, uint256 mintAmountSD, bytes memory to) = abi.decode(
                _payload,
                (uint8, uint256, uint256, uint256, uint256, bytes)
            );

            // swap dst and src because we are headed back
            payload = abi.encode(TYPE_REDEEM_LOCAL_CALL_BACK, dstPoolId, srcPoolId, _c, amountSD, mintAmountSD, to);
        }

        _call(_chainId, TYPE_REDEEM_LOCAL_CALL_BACK, _refundAddress, _lzTxParams, payload);
    }

    //在本地链上赎回资产。它接收一些参数，将它们编码成字节数据，并通过调用_call函数将数据发送到指定的链上
    function redeemLocal(
        uint16 _chainId,
        uint256 _srcPoolId,
        uint256 _dstPoolId,
        address payable _refundAddress,
        Pool.CreditObj memory _c,
        uint256 _amountSD,
        bytes calldata _to,
        IStargateRouter.lzTxObj memory _lzTxParams
    ) external payable onlyRouter {
        bytes memory payload = abi.encode(TYPE_WITHDRAW_REMOTE, _srcPoolId, _dstPoolId, _c, _amountSD, _to);
        _call(_chainId, TYPE_WITHDRAW_REMOTE, _refundAddress, _lzTxParams, payload);
    }

    //发送信用信息。类似于redeemLocal函数，它也将参数编码成字节数据，并通过调用_call函数将数据发送到指定的链上
    function sendCredits(
        uint16 _chainId,
        uint256 _srcPoolId,
        uint256 _dstPoolId,
        address payable _refundAddress,
        Pool.CreditObj memory _c
    ) external payable onlyRouter {
        bytes memory payload = abi.encode(TYPE_ADD_LIQUIDITY, _srcPoolId, _dstPoolId, _c);
        IStargateRouter.lzTxObj memory lzTxObj = IStargateRouter.lzTxObj(0, 0, "0x");
        _call(_chainId, TYPE_ADD_LIQUIDITY, _refundAddress, lzTxObj, payload);
    }

    //查询发送交易所需的手续费。它根据不同的功能类型，编码不同的字节数据，并调用layerZeroEndpoint合约的estimateFees函数来估算手续费
    function quoteLayerZeroFee(
        uint16 _chainId,
        uint8 _functionType,
        bytes calldata _toAddress,
        bytes calldata _transferAndCallPayload,
        IStargateRouter.lzTxObj memory _lzTxParams
    ) external view returns (uint256, uint256) {
        bytes memory payload = "";
        Pool.CreditObj memory c = Pool.CreditObj(1, 1);
        if (_functionType == TYPE_SWAP_REMOTE) {
            Pool.SwapObj memory s = Pool.SwapObj(1, 1, 1, 1, 1, 1);
            payload = abi.encode(TYPE_SWAP_REMOTE, 0, 0, 0, c, s, _toAddress, _transferAndCallPayload);
        } else if (_functionType == TYPE_ADD_LIQUIDITY) {
            payload = abi.encode(TYPE_ADD_LIQUIDITY, 0, 0, c);
        } else if (_functionType == TYPE_REDEEM_LOCAL_CALL_BACK) {
            payload = abi.encode(TYPE_REDEEM_LOCAL_CALL_BACK, 0, 0, c, 0, 0, _toAddress);
        } else if (_functionType == TYPE_WITHDRAW_REMOTE) {
            payload = abi.encode(TYPE_WITHDRAW_REMOTE, 0, 0, c, 0, _toAddress);
        } else {
            revert("Stargate: unsupported function type");
        }

        bytes memory lzTxParamBuilt = _txParamBuilder(_chainId, _functionType, _lzTxParams);
        return layerZeroEndpoint.estimateFees(_chainId, address(this), payload, useLayerZeroToken, lzTxParamBuilt);
    }

    //---------------------------------------------------------------------------
    // dao functions
    // 设置桥接器地址。该函数由合约所有者调用，用于设置特定链的桥接器地址
    function setBridge(uint16 _chainId, bytes calldata _bridgeAddress) external onlyOwner {
        require(bridgeLookup[_chainId].length == 0, "Stargate: Bridge already set!");
        bridgeLookup[_chainId] = _bridgeAddress;
    }

    // 设置不同类型交易的燃料费用。该函数由合约所有者调用，用于设置特定链上特定类型交易的燃料费用
    function setGasAmount(
        uint16 _chainId,
        uint8 _functionType,
        uint256 _gasAmount
    ) external onlyOwner {
        require(_functionType >= 1 && _functionType <= 4, "Stargate: invalid _functionType");
        gasLookup[_chainId][_functionType] = _gasAmount;
    }

    //批准代币转移。该函数由合约所有者调用，用于批准特定代币的转移
    function approveTokenSpender(
        address token,
        address spender,
        uint256 amount
    ) external onlyOwner {
        IERC20(token).approve(spender, amount);
    }

    //设置是否使用Layer Zero代币。该函数由合约所有者调用，用于设置是否启用Layer Zero代币
    function setUseLayerZeroToken(bool enable) external onlyOwner {
        useLayerZeroToken = enable;
    }

    //强制恢复接收。该函数由合约所有者调用，用于强制恢复指定链上的接收功能
    function forceResumeReceive(uint16 _srcChainId, bytes calldata _srcAddress) external override onlyOwner {
        layerZeroEndpoint.forceResumeReceive(_srcChainId, _srcAddress);
    }

    //---------------------------------------------------------------------------
    // generic config for user Application
    //设置配置信息。该函数由合约所有者调用，用于设置特定版本特定链的配置信息
    function setConfig(
        uint16 _version,
        uint16 _chainId,
        uint256 _configType,
        bytes calldata _config
    ) external override onlyOwner {
        layerZeroEndpoint.setConfig(_version, _chainId, _configType, _config);
    }

    // 设置发送版本号。该函数由合约所有者调用，用于设置Layer Zero发送的版本号
    function setSendVersion(uint16 version) external override onlyOwner {
        layerZeroEndpoint.setSendVersion(version);
    }

    // 设置接收版本号。该函数由合约所有者调用，用于设置Layer Zero接收的版本号
    function setReceiveVersion(uint16 version) external override onlyOwner {
        layerZeroEndpoint.setReceiveVersion(version);
    }

    //---------------------------------------------------------------------------
    // INTERNAL functions
    function txParamBuilderType1(uint256 _gasAmount) internal pure returns (bytes memory) {
        uint16 txType = 1;
        return abi.encodePacked(txType, _gasAmount);
    }

    function txParamBuilderType2(
        uint256 _gasAmount,
        uint256 _dstNativeAmount,
        bytes memory _dstNativeAddr
    ) internal pure returns (bytes memory) {
        uint16 txType = 2;
        return abi.encodePacked(txType, _gasAmount, _dstNativeAmount, _dstNativeAddr);
    }

    // 构建事务参数。根据链和类型，它将参数编码为不同类型的事务参数
    function _txParamBuilder(
        uint16 _chainId,
        uint8 _type,
        IStargateRouter.lzTxObj memory _lzTxParams
    ) internal view returns (bytes memory) {
        bytes memory lzTxParam;
        address dstNativeAddr;
        {
            bytes memory dstNativeAddrBytes = _lzTxParams.dstNativeAddr;
            assembly {
                dstNativeAddr := mload(add(dstNativeAddrBytes, 20))
            }
        }

        uint256 totalGas = gasLookup[_chainId][_type].add(_lzTxParams.dstGasForCall);
        if (_lzTxParams.dstNativeAmount > 0 && dstNativeAddr != address(0x0)) {
            lzTxParam = txParamBuilderType2(totalGas, _lzTxParams.dstNativeAmount, _lzTxParams.dstNativeAddr);
        } else {
            lzTxParam = txParamBuilderType1(totalGas);
        }

        return lzTxParam;
    }

    // 调用Layer Zero合约。它接收一些参数，构建事务参数，并通过调用layerZeroEndpoint合约的send函数发送交易
    function _call(
        uint16 _chainId,
        uint8 _type,
        address payable _refundAddress,
        IStargateRouter.lzTxObj memory _lzTxParams,
        bytes memory _payload
    ) internal {
        bytes memory lzTxParamBuilt = _txParamBuilder(_chainId, _type, _lzTxParams);
        uint64 nextNonce = layerZeroEndpoint.getOutboundNonce(_chainId, address(this)) + 1;
        layerZeroEndpoint.send{value: msg.value}(_chainId, bridgeLookup[_chainId], _payload, _refundAddress, address(this), lzTxParamBuilt);
        emit SendMsg(_type, nextNonce);
    }

    // 放弃合约所有权。这是OpenZeppelin的Ownable合约中的函数，用于放弃合约的所有权
    function renounceOwnership() public override onlyOwner {}
}
