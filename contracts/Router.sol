// SPDX-License-Identifier: BUSL-1.1

pragma solidity 0.7.6;
pragma abicoder v2;

// imports
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "./Factory.sol";
import "./Pool.sol";
import "./Bridge.sol";

// interfaces
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "./interfaces/IStargateRouter.sol";
import "./interfaces/IStargateReceiver.sol";

// libraries
import "@openzeppelin/contracts/math/SafeMath.sol";

contract Router is IStargateRouter, Ownable, ReentrancyGuard {
    using SafeMath for uint256;

    //---------------------------------------------------------------------------
    // CONSTANTS
    uint8 internal constant TYPE_REDEEM_LOCAL_RESPONSE = 1; // 恢复本地赎回响应的类型
    uint8 internal constant TYPE_REDEEM_LOCAL_CALLBACK_RETRY = 2; // 重试本地赎回回调的类型
    uint8 internal constant TYPE_SWAP_REMOTE_RETRY = 3; // 重试远程交换的类型

    //---------------------------------------------------------------------------
    // STRUCTS
    struct CachedSwap { // 缓存的交换信息结构体
        address token;
        uint256 amountLD;
        address to;
        bytes payload;
    }

    //---------------------------------------------------------------------------
    // VARIABLES
    Factory public factory; // 工厂合约，用于创建池子
    address public protocolFeeOwner; // 可以调用方法取出池子收集的协议费用
    address public mintFeeOwner; // 可以调用方法取出池子收集的铸造费用
    Bridge public bridge; // Stargate连接的桥接器
    mapping(uint16 => mapping(bytes => mapping(uint256 => bytes))) public revertLookup; // 用于查找恢复的非本地合约函数的映射
    mapping(uint16 => mapping(bytes => mapping(uint256 => CachedSwap))) public cachedSwapLookup; // 用于缓存待执行的交换信息的映射

    //---------------------------------------------------------------------------
    // EVENTS
    event Revert(uint8 bridgeFunctionType, uint16 chainId, bytes srcAddress, uint256 nonce); // 当交换或其他操作失败时发出的事件，用于调试
    event CachedSwapSaved(uint16 chainId, bytes srcAddress, uint256 nonce, address token, uint256 amountLD, address to, bytes payload, bytes reason); // 当交换被缓存时发出的事件
    event RevertRedeemLocal(uint16 srcChainId, uint256 _srcPoolId, uint256 _dstPoolId, bytes to, uint256 redeemAmountSD, uint256 mintAmountSD, uint256 indexed nonce, bytes indexed srcAddress); // 当本地赎回操作失败时发出的事件
    event RedeemLocalCallback(uint16 srcChainId, bytes indexed srcAddress, uint256 indexed nonce, uint256 srcPoolId, uint256 dstPoolId, address to, uint256 amountSD, uint256 mintAmountSD); // 当本地赎回回调成功时发出的事件

    //---------------------------------------------------------------------------
    // MODIFIERS
    modifier onlyBridge() { // 仅限桥接器调用的修饰符
        require(msg.sender == address(bridge), "Bridge: caller must be Bridge.");
        _;
    }

    constructor() {}

    function setBridgeAndFactory(Bridge _bridge, Factory _factory) external onlyOwner { // 设置桥接器和工厂合约
        require(address(bridge) == address(0x0) && address(factory) == address(0x0), "Stargate: bridge and factory already initialized"); // 只能初始化一次
        require(address(_bridge) != address(0x0), "Stargate: bridge cant be 0x0");
        require(address(_factory) != address(0x0), "Stargate: factory cant be 0x0");

        bridge = _bridge;
        factory = _factory;
    }

    //---------------------------------------------------------------------------
    // VIEWS
    function _getPool(uint256 _poolId) internal view returns (Pool pool) { // 获取池子的内部函数
        pool = factory.getPool(_poolId);
        require(address(pool) != address(0x0), "Stargate: Pool does not exist"); // 池子存在，否则报错
    }

    //---------------------------------------------------------------------------
    // INTERNAL
    function _safeTransferFrom( // 安全转移代币的内部函数
        address token,
        address from,
        address to,
        uint256 value
    ) private {
        // bytes4(keccak256(bytes('transferFrom(address,address,uint256)')));
        (bool success, bytes memory data) = token.call(abi.encodeWithSelector(0x23b872dd, from, to, value)); // 调用代币的transferFrom方法
        require(success && (data.length == 0 || abi.decode(data, (bool))), "Stargate: TRANSFER_FROM_FAILED"); // 转移成功，否则报错
    }

    //---------------------------------------------------------------------------
    // LOCAL CHAIN FUNCTIONS
    function addLiquidity( // 增加流动性的方法
        uint256 _poolId,
        uint256 _amountLD,
        address _to
    ) external override nonReentrant {
        Pool pool = _getPool(_poolId); // 获取池子
        uint256 convertRate = pool.convertRate(); // 获取换算比率
        _amountLD = _amountLD.div(convertRate).mul(convertRate); // 根据换算比率调整资产数量
        _safeTransferFrom(pool.token(), msg.sender, address(pool), _amountLD); // 将资产转移到池子合约
        pool.mint(_to, _amountLD); // 增加流动性
    }

    function swap( // 进行交换的方法
        uint16 _dstChainId,
        uint256 _srcPoolId,
        uint256 _dstPoolId,
        address payable _refundAddress,
        uint256 _amountLD,
        uint256 _minAmountLD,
        lzTxObj memory _lzTxParams,
        bytes calldata _to,
        bytes calldata _payload
    ) external payable override nonReentrant {
        require(_amountLD > 0, "Stargate: cannot swap 0"); // 资产数量不能为零
        require(_refundAddress != address(0x0), "Stargate: _refundAddress cannot be 0x0"); // 退款地址不能是0x0
        Pool.SwapObj memory s; // 定义SwapObj对象
        Pool.CreditObj memory c; // 定义CreditObj对象
        {
            Pool pool = _getPool(_srcPoolId); // 获取源池子
            {
                uint256 convertRate = pool.convertRate(); // 获取换算比率
                _amountLD = _amountLD.div(convertRate).mul(convertRate); // 根据换算比率调整资产数量
            }

            s = pool.swap(_dstChainId, _dstPoolId, msg.sender, _amountLD, _minAmountLD, true); // 进行交换
            _safeTransferFrom(pool.token(), msg.sender, address(pool), _amountLD); // 将资产转移到池子合约
            c = pool.sendCredits(_dstChainId, _dstPoolId); // 发送信用信息
        }
        bridge.swap{value: msg.value}(_dstChainId, _srcPoolId, _dstPoolId, _refundAddress, c, s, _lzTxParams, _to, _payload); // 调用桥接器进行交换
    }

    //redeemRemote 函数用于在远端链上赎回 LP 代币并将资产转移到当前链上
    function redeemRemote(
        uint16 _dstChainId,
        uint256 _srcPoolId,
        uint256 _dstPoolId,
        address payable _refundAddress,
        uint256 _amountLP,
        uint256 _minAmountLD,
        bytes calldata _to,
        lzTxObj memory _lzTxParams
    ) external payable override nonReentrant {
        require(_refundAddress != address(0x0), "Stargate: _refundAddress cannot be 0x0"); // 确保 _refundAddress 不是空地址
        require(_amountLP > 0, "Stargate: not enough lp to redeemRemote"); // 确保 _amountLP 大于零
        Pool.SwapObj memory s;
        Pool.CreditObj memory c;
        {
            Pool pool = _getPool(_srcPoolId); // 获取指定 _srcPoolId 的 Pool 对象
            uint256 amountLD = pool.amountLPtoLD(_amountLP); // 将 _amountLP 转换为对应的 LD 数量
            // 执行一个没有流动性的交换
            s = pool.swap(_dstChainId, _dstPoolId, msg.sender, amountLD, _minAmountLD, false);
            pool.redeemRemote(_dstChainId, _dstPoolId, msg.sender, _amountLP); // 在目标链上赎回 LP 代币
            c = pool.sendCredits(_dstChainId, _dstPoolId); // 向目标链发送贷款信用额
        }
        // 相当于进行一个交换，没有载荷（"0x"），无目标链调用的 gas 数量为 0
        bridge.swap{value: msg.value}(_dstChainId, _srcPoolId, _dstPoolId, _refundAddress, c, s, _lzTxParams, _to, "");
    }

    //instantRedeemLocal 函数用于在当前链上立即兑换 LP 代币为 SD 代币，并将资产转移给指定地址 _to。函数的参数包括源池 ID _srcPoolId、
    //LP 代币数量 _amountLP 以及接收地址 _to
    function instantRedeemLocal(
        uint16 _srcPoolId,
        uint256 _amountLP,
        address _to
    ) external override nonReentrant returns (uint256 amountSD) {
        require(_amountLP > 0, "Stargate: not enough lp to redeem"); // 确保 _amountLP 大于零
        Pool pool = _getPool(_srcPoolId); // 获取指定 _srcPoolId 的 Pool 对象
        amountSD = pool.instantRedeemLocal(msg.sender, _amountLP, _to); // 在当前链上立即兑换 LP 代币为 SD 代币，并将资产转至 _to 地址
    }

    //redeemLocal 函数用于在当前链上兑换 LP 代币为 SD 代币，并将资产转移到目标链上的合约地址。函数的参数包括目标链 ID _dstChainId、
    //源池 ID _srcPoolId、目标池 ID _dstPoolId、退款地址 _refundAddress、LP 代币数量 _amountLP、调用的目标合约地址 _to、以及
    //lzTxObj 结构体 _lzTxParams。
    function redeemLocal(
        uint16 _dstChainId,
        uint256 _srcPoolId,
        uint256 _dstPoolId,
        address payable _refundAddress,
        uint256 _amountLP,
        bytes calldata _to,
        lzTxObj memory _lzTxParams
    ) external payable override nonReentrant {
        require(_refundAddress != address(0x0), "Stargate: _refundAddress cannot be 0x0"); // 确保 _refundAddress 不是空地址
        Pool pool = _getPool(_srcPoolId); // 获取指定 _srcPoolId 的 Pool 对象
        require(_amountLP > 0, "Stargate: not enough lp to redeem"); // 确保 _amountLP 大于零
        uint256 amountSD = pool.redeemLocal(msg.sender, _amountLP, _dstChainId, _dstPoolId, _to); // 在当前链上兑换 LP 代币为 SD 代币，并将资产转至目标链的合约地址 _to
        require(amountSD > 0, "Stargate: not enough lp to redeem with amountSD"); // 确保兑换得到的 SD 代币数量大于零

        Pool.CreditObj memory c = pool.sendCredits(_dstChainId, _dstPoolId); // 向目标链发送贷款信用额
        bridge.redeemLocal{value: msg.value}(_dstChainId, _srcPoolId, _dstPoolId, _refundAddress, c, amountSD, _to, _lzTxParams); // 调用 bridge 合约的 redeemLocal 函数执行兑换操作
    }

    //用于向目标链发送贷款信用额。函数的参数包括目标链 ID _dstChainId、源池 ID _srcPoolId、目标池 ID _dstPoolId、退款地址 _refundAddress
    function sendCredits(
        uint16 _dstChainId,
        uint256 _srcPoolId,
        uint256 _dstPoolId,
        address payable _refundAddress
    ) external payable override nonReentrant {
        require(_refundAddress != address(0x0), "Stargate: _refundAddress cannot be 0x0"); // 确保 _refundAddress 不是空地址
        Pool pool = _getPool(_srcPoolId); // 获取指定 _srcPoolId 的 Pool 对象
        Pool.CreditObj memory c = pool.sendCredits(_dstChainId, _dstPoolId); // 向目标链发送贷款信用额
        bridge.sendCredits{value: msg.value}(_dstChainId, _srcPoolId, _dstPoolId, _refundAddress, c); // 调用 bridge 合约的 sendCredits 函数执行发送贷款信用额操作
    }

    //用于获取在零层链上执行特定合约调用所需的费用
    function quoteLayerZeroFee(
        uint16 _dstChainId,
        uint8 _functionType,
        bytes calldata _toAddress,
        bytes calldata _transferAndCallPayload,
        Router.lzTxObj memory _lzTxParams
    ) external view override returns (uint256, uint256) {
        return bridge.quoteLayerZeroFee(_dstChainId, _functionType, _toAddress, _transferAndCallPayload, _lzTxParams);
    }

    //处理在执行本地兑换操作时发生错误的情况
    function revertRedeemLocal(
        uint16 _dstChainId,
        bytes calldata _srcAddress,
        uint256 _nonce,
        address payable _refundAddress,
        lzTxObj memory _lzTxParams
    ) external payable {
        require(_refundAddress != address(0x0), "Stargate: _refundAddress cannot be 0x0");
        bytes memory payload = revertLookup[_dstChainId][_srcAddress][_nonce];
        require(payload.length > 0, "Stargate: no retry revert");
        {
            uint8 functionType;
            assembly {
                functionType := mload(add(payload, 32))
            }
            require(functionType == TYPE_REDEEM_LOCAL_RESPONSE, "Stargate: invalid function type");
        }

        // empty it
        revertLookup[_dstChainId][_srcAddress][_nonce] = "";

        uint256 srcPoolId;
        uint256 dstPoolId;
        assembly {
            srcPoolId := mload(add(payload, 64))
            dstPoolId := mload(add(payload, 96))
        }

        Pool.CreditObj memory c;
        {
            Pool pool = _getPool(dstPoolId);
            c = pool.sendCredits(_dstChainId, srcPoolId);
        }

        bridge.redeemLocalCallback{value: msg.value}(_dstChainId, _refundAddress, c, _lzTxParams, payload);
    }


    //处理在执行某些操作时发生错误的情况，例如超时或目标链上的交换失败
    function retryRevert(
        uint16 _srcChainId,
        bytes calldata _srcAddress,
        uint256 _nonce
    ) external payable {
        bytes memory payload = revertLookup[_srcChainId][_srcAddress][_nonce];
        require(payload.length > 0, "Stargate: no retry revert");

        // empty it
        revertLookup[_srcChainId][_srcAddress][_nonce] = "";

        uint8 functionType;
        assembly {
            functionType := mload(add(payload, 32))
        }

        if (functionType == TYPE_REDEEM_LOCAL_CALLBACK_RETRY) {
            (, uint256 srcPoolId, uint256 dstPoolId, address to, uint256 amountSD, uint256 mintAmountSD) = abi.decode(
                payload,
                (uint8, uint256, uint256, address, uint256, uint256)
            );
            _redeemLocalCallback(_srcChainId, _srcAddress, _nonce, srcPoolId, dstPoolId, to, amountSD, mintAmountSD);
        }
        // for retrying the swapRemote. if it fails again, retry
        else if (functionType == TYPE_SWAP_REMOTE_RETRY) {
            (, uint256 srcPoolId, uint256 dstPoolId, uint256 dstGasForCall, address to, Pool.SwapObj memory s, bytes memory p) = abi.decode(
                payload,
                (uint8, uint256, uint256, uint256, address, Pool.SwapObj, bytes)
            );
            _swapRemote(_srcChainId, _srcAddress, _nonce, srcPoolId, dstPoolId, dstGasForCall, to, s, p);
        } else {
            revert("Stargate: invalid function type");
        }
    }

    function clearCachedSwap(
        uint16 _srcChainId,
        bytes calldata _srcAddress,
        uint256 _nonce
    ) external {
        CachedSwap memory cs = cachedSwapLookup[_srcChainId][_srcAddress][_nonce];
        require(cs.to != address(0x0), "Stargate: cache already cleared");
        // clear the data
        cachedSwapLookup[_srcChainId][_srcAddress][_nonce] = CachedSwap(address(0x0), 0, address(0x0), "");
        IStargateReceiver(cs.to).sgReceive(_srcChainId, _srcAddress, _nonce, cs.token, cs.amountLD, cs.payload);
    }

    //在跨链操作中将信用额度转移到目标链上
    function creditChainPath(
        uint16 _dstChainId,
        uint256 _dstPoolId,
        uint256 _srcPoolId,
        Pool.CreditObj memory _c
    ) external onlyBridge {
        Pool pool = _getPool(_srcPoolId);
        pool.creditChainPath(_dstChainId, _dstPoolId, _c);
    }

    //---------------------------------------------------------------------------
    // REMOTE CHAIN FUNCTIONS
    // 用于在目标链上执行本地兑换检查
    function redeemLocalCheckOnRemote(
        uint16 _srcChainId,
        bytes memory _srcAddress,
        uint256 _nonce,
        uint256 _srcPoolId,
        uint256 _dstPoolId,
        uint256 _amountSD,
        bytes calldata _to
    ) external onlyBridge {
        Pool pool = _getPool(_dstPoolId);
        try pool.redeemLocalCheckOnRemote(_srcChainId, _srcPoolId, _amountSD) returns (uint256 redeemAmountSD, uint256 mintAmountSD) {
            revertLookup[_srcChainId][_srcAddress][_nonce] = abi.encode(
                TYPE_REDEEM_LOCAL_RESPONSE,
                _srcPoolId,
                _dstPoolId,
                redeemAmountSD,
                mintAmountSD,
                _to
            );
            emit RevertRedeemLocal(_srcChainId, _srcPoolId, _dstPoolId, _to, redeemAmountSD, mintAmountSD, _nonce, _srcAddress);
        } catch {
            // if the func fail, return [swapAmount: 0, mintAMount: _amountSD]
            // swapAmount represents the amount of chainPath balance deducted on the remote side, which because the above tx failed, should be 0
            // mintAmount is the full amount of tokens the user attempted to redeem on the src side, which gets converted back into the lp amount
            revertLookup[_srcChainId][_srcAddress][_nonce] = abi.encode(TYPE_REDEEM_LOCAL_RESPONSE, _srcPoolId, _dstPoolId, 0, _amountSD, _to);
            emit Revert(TYPE_REDEEM_LOCAL_RESPONSE, _srcChainId, _srcAddress, _nonce);
        }
    }

    //用于处理本地兑换回调
    function redeemLocalCallback(
        uint16 _srcChainId,
        bytes memory _srcAddress,
        uint256 _nonce,
        uint256 _srcPoolId,
        uint256 _dstPoolId,
        address _to,
        uint256 _amountSD,
        uint256 _mintAmountSD
    ) external onlyBridge {
        _redeemLocalCallback(_srcChainId, _srcAddress, _nonce, _srcPoolId, _dstPoolId, _to, _amountSD, _mintAmountSD);
    }

    // 用于在本地兑换回调时调用的内部函数
    // 参数：
    // _srcChainId: 源链的链ID
    // _srcAddress: 源地址
    // _nonce: 交易的nonce
    // _srcPoolId: 源池ID
    // _dstPoolId: 目标池ID
    // _to: 接收资产的地址
    // _amountSD: 源池中待提取资产的数量
    // _mintAmountSD: 待铸造的可提取资产的数量
    function _redeemLocalCallback(
        uint16 _srcChainId,
        bytes memory _srcAddress,
        uint256 _nonce,
        uint256 _srcPoolId,
        uint256 _dstPoolId,
        address _to,
        uint256 _amountSD,
        uint256 _mintAmountSD
    ) internal {
        Pool pool = _getPool(_dstPoolId);
        try pool.redeemLocalCallback(_srcChainId, _srcPoolId, _to, _amountSD, _mintAmountSD) {} catch {
            revertLookup[_srcChainId][_srcAddress][_nonce] = abi.encode(
                TYPE_REDEEM_LOCAL_CALLBACK_RETRY,
                _srcPoolId,
                _dstPoolId,
                _to,
                _amountSD,
                _mintAmountSD
            );
            emit Revert(TYPE_REDEEM_LOCAL_CALLBACK_RETRY, _srcChainId, _srcAddress, _nonce);
        }
        emit RedeemLocalCallback(_srcChainId, _srcAddress, _nonce, _srcPoolId, _dstPoolId, _to, _amountSD, _mintAmountSD);
    }

    // 进行远程兑换操作
    // 参数：
    // _srcChainId: 源链的链ID
    // _srcAddress: 源地址
    // _nonce: 交易的nonce
    // _srcPoolId: 源池ID
    // _dstPoolId: 目标池ID
    // _dstGasForCall: 目标合约调用所需的gas数量
    // _to: 接收资产的地址
    // _s: 兑换操作的参数对象
    // _payload: 外部合约调用时的附加数据
    function swapRemote(
        uint16 _srcChainId,
        bytes memory _srcAddress,
        uint256 _nonce,
        uint256 _srcPoolId,
        uint256 _dstPoolId,
        uint256 _dstGasForCall,
        address _to,
        Pool.SwapObj memory _s,
        bytes memory _payload
    ) external onlyBridge {
        _swapRemote(_srcChainId, _srcAddress, _nonce, _srcPoolId, _dstPoolId, _dstGasForCall, _to, _s, _payload);
    }

    // 进行远程兑换操作的内部函数
    // 参数和功能与swapRemote函数相同，详细请参考swapRemote函数的注释
    function _swapRemote(
        uint16 _srcChainId,
        bytes memory _srcAddress,
        uint256 _nonce,
        uint256 _srcPoolId,
        uint256 _dstPoolId,
        uint256 _dstGasForCall,
        address _to,
        Pool.SwapObj memory _s,
        bytes memory _payload
    ) internal {
        // 获取目标池对象
        Pool pool = _getPool(_dstPoolId);
        // 首先尝试捕获swapRemote函数的异常
        try pool.swapRemote(_srcChainId, _srcPoolId, _to, _s) returns (uint256 amountLD) {
            if (_payload.length > 0) {
                // 然后尝试捕获外部合约调用的异常
                try IStargateReceiver(_to).sgReceive{gas: _dstGasForCall}(_srcChainId, _srcAddress, _nonce, pool.token(), amountLD, _payload) {
                    // 如果成功调用，什么都不做
                } catch (bytes memory reason) {
                    cachedSwapLookup[_srcChainId][_srcAddress][_nonce] = CachedSwap(pool.token(), amountLD, _to, _payload);
                    emit CachedSwapSaved(_srcChainId, _srcAddress, _nonce, pool.token(), amountLD, _to, _payload, reason);
                }
            }
        } catch {
            revertLookup[_srcChainId][_srcAddress][_nonce] = abi.encode(
                TYPE_SWAP_REMOTE_RETRY,
                _srcPoolId,
                _dstPoolId,
                _dstGasForCall,
                _to,
                _s,
                _payload
            );
            emit Revert(TYPE_SWAP_REMOTE_RETRY, _srcChainId, _srcAddress, _nonce);
        }
    }

    // DAO调用：创建池子
    // 参数：
    // _poolId: 池ID
    // _token: 池子中的资产地址
    // _sharedDecimals: 共享的小数位数
    // _localDecimals: 本地的小数位数
    // _name: 池子的名称
    // _symbol: 池子的符号
    // 返回：
    // 创建的池子地址
    function createPool(
        uint256 _poolId,
        address _token,
        uint8 _sharedDecimals,
        uint8 _localDecimals,
        string memory _name,
        string memory _symbol
    ) external onlyOwner returns (address) {
        require(_token != address(0x0), "Stargate: _token cannot be 0x0");
        return factory.createPool(_poolId, _token, _sharedDecimals, _localDecimals, _name, _symbol);
    }


    // 创建链路路径，连接两个池子之间的不同链上的资产流动
    // 参数：
    // _poolId: 源池子的ID
    // _dstChainId: 目标链的链ID
    // _dstPoolId: 目标链上的目标池子ID
    // _weight: 链路路径的权重
    function createChainPath(
        uint256 _poolId,
        uint16 _dstChainId,
        uint256 _dstPoolId,
        uint256 _weight
    ) external onlyOwner {
        Pool pool = _getPool(_poolId);
        pool.createChainPath(_dstChainId, _dstPoolId, _weight);
    }

    // 激活链路路径，使两个池子之间的资产流动开始生效
    // 参数：
    // _poolId: 源池子的ID
    // _dstChainId: 目标链的链ID
    // _dstPoolId: 目标链上的目标池子ID
    function activateChainPath(
        uint256 _poolId,
        uint16 _dstChainId,
        uint256 _dstPoolId
    ) external onlyOwner {
        Pool pool = _getPool(_poolId);
        pool.activateChainPath(_dstChainId, _dstPoolId);
    }

    // 设置链路路径的权重
    // 参数：
    // _poolId: 源池子的ID
    // _dstChainId: 目标链的链ID
    // _dstPoolId: 目标链上的目标池子ID
    // _weight: 链路路径的权重
    function setWeightForChainPath(
        uint256 _poolId,
        uint16 _dstChainId,
        uint256 _dstPoolId,
        uint16 _weight
    ) external onlyOwner {
        Pool pool = _getPool(_poolId);
        pool.setWeightForChainPath(_dstChainId, _dstPoolId, _weight);
    }

    // 设置协议费用的所有者地址
    // 参数：
    // _owner: 协议费用的所有者地址
    function setProtocolFeeOwner(address _owner) external onlyOwner {
        require(_owner != address(0x0), "Stargate: _owner cannot be 0x0");
        protocolFeeOwner = _owner;
    }

    // 设置铸造费用的所有者地址
    // 参数：
    // _owner: 铸造费用的所有者地址
    function setMintFeeOwner(address _owner) external onlyOwner {
        require(_owner != address(0x0), "Stargate: _owner cannot be 0x0");
        mintFeeOwner = _owner;
    }

    // 设置池子的费用
    // 参数：
    // _poolId: 池子的ID
    // _mintFeeBP: 铸造费用的百分比（以基点为单位）
    function setFees(uint256 _poolId, uint256 _mintFeeBP) external onlyOwner {
        Pool pool = _getPool(_poolId);
        pool.setFee(_mintFeeBP);
    }

    // 设置池子的费用计算库地址
    // 参数：
    // _poolId: 池子的ID
    // _feeLibraryAddr: 费用计算库的地址
    function setFeeLibrary(uint256 _poolId, address _feeLibraryAddr) external onlyOwner {
        Pool pool = _getPool(_poolId);
        pool.setFeeLibrary(_feeLibraryAddr);
    }

    // 设置是否停止池子中的资产兑换
    // 参数：
    // _poolId: 池子的ID
    // _swapStop: 是否停止资产兑换
    function setSwapStop(uint256 _poolId, bool _swapStop) external onlyOwner {
        Pool pool = _getPool(_poolId);
        pool.setSwapStop(_swapStop);
    }

    // 设置池子中各种参数的变动值
    // 参数：
    // _poolId: 池子的ID
    // _batched: 是否启用批量模式
    // _swapDeltaBP: 兑换手续费变动值（以基点为单位）
    // _lpDeltaBP: LP手续费变动值（以基点为单位）
    // _defaultSwapMode: 默认兑换模式（普通或批量）
    // _defaultLPMode: 默认LP模式（普通或批量）
    function setDeltaParam(
        uint256 _poolId,
        bool _batched,
        uint256 _swapDeltaBP,
        uint256 _lpDeltaBP,
        bool _defaultSwapMode,
        bool _defaultLPMode
    ) external onlyOwner {
        Pool pool = _getPool(_poolId);
        pool.setDeltaParam(_batched, _swapDeltaBP, _lpDeltaBP, _defaultSwapMode, _defaultLPMode);
    }

    // 调用池子中的Delta函数，用于调整资产比例
    // 参数：
    // _poolId: 池子的ID
    // _fullMode: 是否使用完整模式调用
    function callDelta(uint256 _poolId, bool _fullMode) external {
        Pool pool = _getPool(_poolId);
        pool.callDelta(_fullMode);
    }

    // 提取铸造费用余额
    // 参数：
    // _poolId: 池子的ID
    // _to: 提取的目标地址
    function withdrawMintFee(uint256 _poolId, address _to) external {
        require(mintFeeOwner == msg.sender, "Stargate: only mintFeeOwner");
        Pool pool = _getPool(_poolId);
        pool.withdrawMintFeeBalance(_to);
    }

    // 提取协议费用余额
    // 参数：
    // _poolId: 池子的ID
    // _to: 提取的目标地址
    function withdrawProtocolFee(uint256 _poolId, address _to) external {
        require(protocolFeeOwner == msg.sender, "Stargate: only protocolFeeOwner");
        Pool pool = _getPool(_poolId);
        pool.withdrawProtocolFeeBalance(_to);
    }
}
