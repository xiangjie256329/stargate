// SPDX-License-Identifier: BUSL-1.1

pragma solidity 0.7.6;
pragma abicoder v2;

// imports
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "./LPTokenERC20.sol";
import "./interfaces/IStargateFeeLibrary.sol";

// libraries
import "@openzeppelin/contracts/math/SafeMath.sol";

/// Pool contracts on other chains and managed by the Stargate protocol.
contract Pool is LPTokenERC20, ReentrancyGuard {
    using SafeMath for uint256;

    //---------------------------------------------------------------------------
    // CONSTANTS
    bytes4 private constant SELECTOR = bytes4(keccak256(bytes("transfer(address,uint256)")));
    // 定义常量SELECTOR，它是用来调用ERC20代币的transfer方法的函数签名

    uint256 public constant BP_DENOMINATOR = 10000;
    // 定义常量BP_DENOMINATOR，它是用于计算手续费的系数

    //---------------------------------------------------------------------------
    // STRUCTS
    struct ChainPath {
        bool ready;     // 标识链路是否已经建立
        uint16 dstChainId;  // 目标链的id
        uint256 dstPoolId;  // 目标池子的id
        uint256 weight;     // 权重，用于计算池子占比
        uint256 balance;    // 余额，表示当前池子中代币的余额
        uint256 lkb;        // 最后一次刷新余额的时间戳
        uint256 credits;    // 信用分，用于计算Delta相关的数据
        uint256 idealBalance;   // 理想余额，用于计算Delta相关的数据
    }

    struct SwapObj {
        uint256 amount;     // 本地链兑换到目标链的代币数量
        uint256 eqFee;      // 本地链交易手续费
        uint256 eqReward;   // 本地链兑换奖励
        uint256 lpFee;      // 池子兑换手续费
        uint256 protocolFee;    // 协议手续费
        uint256 lkbRemove;  // 上一次更新余额的时间戳
    }

    struct CreditObj {
        uint256 credits;    // 信用分，表示链路节点间互相信任的程度
        uint256 idealBalance;   // 理想余额，用于计算Delta相关的数据
    }

    //---------------------------------------------------------------------------
    // VARIABLES

    // chainPath
    ChainPath[] public chainPaths;  // 存储连接到此池的其他链的ChainPath结构体数组
    mapping(uint16 => mapping(uint256 => uint256)) public chainPathIndexLookup;  // 存储链的id和池子的id之间的关联索引


    // metadata
    uint256 public immutable poolId;  // 池子id，用于标识同一个池子在不同链上的实例
    uint256 public sharedDecimals;    // 共享小数位（不同链上代币的最小公倍数）
    uint256 public localDecimals;     // 本地链代币的小数位
    uint256 public immutable convertRate;  // 汇率，用于将代币在不同链上进行兑换
    address public immutable token;   // 代币地址
    address public immutable router;  // 路由合约地址

    bool public stopSwap;    // 是否停止交易的标志


    // Fee and Liquidity
    uint256 public totalLiquidity;  // 总流动性
    uint256 public totalWeight;     // 池子的总权重
    uint256 public mintFeeBP;       // 买入（deposit/mint）时的手续费
    uint256 public protocolFeeBalance;   // 协议手续费的余额
    uint256 public mintFeeBalance;   // 买入时的手续费余额
    uint256 public eqFeePool;   // 兑换奖励的池子余额，以共享小数位表示
    address public feeLibrary;  // 手续费计算合约地址


    // Delta related
    uint256 public deltaCredit; // Delta算法中的信用分
    bool public batched;    // 是否批量处理交易
    bool public defaultSwapMode;     // 默认的兑换模式
    bool public defaultLPMode;       // 默认的流动性协议模式
    uint256 public swapDeltaBP;      // 激活Delta算法的最低信用分限制
    uint256 public lpDeltaBP;        // 激活Delta算法的最低信用分限制
                                     // 根据信用分动态调整兑换交易和流动性协议的行为

    //---------------------------------------------------------------------------
    // EVENTS
    event Mint(address to, uint256 amountLP, uint256 amountSD, uint256 mintFeeAmountSD);  // 买入事件
    event Burn(address from, uint256 amountLP, uint256 amountSD);     // 卖出事件
    event RedeemLocalCallback(address _to, uint256 _amountSD, uint256 _amountToMintSD);  // 本地链代币的回收事件
    event Swap(
        uint16 chainId, uint256 dstPoolId, address from, uint256 amountSD, uint256 eqReward,
        uint256 eqFee, uint256 protocolFee, uint256 lpFee
    );  // 兑换事件，从本地链兑换到目标链
    event SendCredits(uint16 dstChainId, uint256 dstPoolId, uint256 credits, uint256 idealBalance);  // 发送信用分事件
    event RedeemRemote(uint16 chainId, uint256 dstPoolId, address from, uint256 amountLP, uint256 amountSD);  // 远程兑换事件
    event RedeemLocal(address from, uint256 amountLP, uint256 amountSD, uint16 chainId, uint256 dstPoolId, bytes to);  // 本地兑换事件
    event InstantRedeemLocal(address from, uint256 amountLP, uint256 amountSD, address to);   // 立即兑换事件
    event CreditChainPath(uint16 chainId, uint256 srcPoolId, uint256 amountSD, uint256 idealBalance);  // 发送信用分事件
    event SwapRemote(address to, uint256 amountSD, uint256 protocolFee, uint256 dstFee);  // 远程兑换事件
    event WithdrawRemote(uint16 srcChainId, uint256 srcPoolId, uint256 swapAmount, uint256 mintAmount);  // 远程提现事件
    event ChainPathUpdate(uint16 dstChainId, uint256 dstPoolId, uint256 weight);  // 链路更新事件
    event FeesUpdated(uint256 mintFeeBP);  // 手续费更新事件
    event FeeLibraryUpdated(address feeLibraryAddr);  // 手续费计算合约地址更新事件
    event StopSwapUpdated(bool swapStop);         // 是否停止交易更新事件
    event WithdrawProtocolFeeBalance(address to, uint256 amountSD);   // 提取协议手续费余额事件
    event WithdrawMintFeeBalance(address to, uint256 amountSD);       // 提取买入手续费余额事件
    event DeltaParamUpdated(bool batched, uint256 swapDeltaBP, uint256 lpDeltaBP, bool defaultSwapMode, bool defaultLPMode);  // Delta算法参数更新事件

    //---------------------------------------------------------------------------
    // MODIFIERS
    modifier onlyRouter() {
        require(msg.sender == router, "Stargate: only the router can call this method");
        _;
    }

    constructor(
        uint256 _poolId, address _router, address _token, uint256 _sharedDecimals,
        uint256 _localDecimals, address _feeLibrary, string memory _name, string memory _symbol
    ) LPTokenERC20(_name, _symbol) {
        require(_token != address(0x0), "Stargate: _token cannot be 0x0");
        require(_router != address(0x0), "Stargate: _router cannot be 0x0");
        poolId = _poolId;
        router = _router;
        token = _token;
        sharedDecimals = _sharedDecimals;
        decimals = uint8(_sharedDecimals);
        localDecimals = _localDecimals;
        convertRate = 10**(uint256(localDecimals).sub(sharedDecimals));
        totalWeight = 0;
        feeLibrary = _feeLibrary;

        // Delta algo related
        batched = false;
        defaultSwapMode = true;
        defaultLPMode = true;
    }

    function getChainPathsLength() public view returns (uint256) {
        return chainPaths.length;
    }

    //---------------------------------------------------------------------------
    // LOCAL CHAIN FUNCTIONS
    // 在本地链上铸造新的代币，并将其分发给指定地址
    function mint(address _to, uint256 _amountLD) external nonReentrant onlyRouter returns (uint256) {
        return _mintLocal(_to, _amountLD, true, true);
    }

    // 在本地链和远程链之间进行资产交换
    function swap(
        uint16 _dstChainId,
        uint256 _dstPoolId,
        address _from,
        uint256 _amountLD,
        uint256 _minAmountLD,
        bool newLiquidity
    ) external nonReentrant onlyRouter returns (SwapObj memory) {
        // 检查交换是否被停止
        require(!stopSwap, "Stargate: swap func stopped");
        ChainPath storage cp = getAndCheckCP(_dstChainId, _dstPoolId);
        // 检查远程链路是否准备就绪
        require(cp.ready == true, "Stargate: counter chainPath is not ready");

        // 将本地链上的代币金额转换为远程链上的金额
        uint256 amountSD = amountLDtoSD(_amountLD);
        uint256 minAmountSD = amountLDtoSD(_minAmountLD);

        // 从费用库中获取交易所需的费用信息
        SwapObj memory s = IStargateFeeLibrary(feeLibrary).getFees(poolId, _dstPoolId, _dstChainId, _from, amountSD);

        // 更新等值手续费和奖励
        eqFeePool = eqFeePool.sub(s.eqReward);
        // 更新用户将获得的金额（扣除手续费）
        s.amount = amountSD.sub(s.eqFee).sub(s.protocolFee).sub(s.lpFee);
        // 检查交易滑点是否过高
        require(s.amount.add(s.eqReward) >= minAmountSD, "Stargate: slippage too high");

        // 行为
        // - protocolFee：远程链上保留并提取
        // - eqFee：远程链上保留并提取
        // - lpFee：远程链上保留，并可以在任何地方提取
        // 从远程链上扣除lpFee和eqReward
        s.lkbRemove = amountSD.sub(s.lpFee).add(s.eqReward);
        // 检查远程链上的余额是否足够支付
        require(cp.balance >= s.lkbRemove, "Stargate: dst balance too low");
        cp.balance = cp.balance.sub(s.lkbRemove);

        if (newLiquidity) {
            deltaCredit = deltaCredit.add(amountSD).add(s.eqReward);
        } else if (s.eqReward > 0) {
            deltaCredit = deltaCredit.add(s.eqReward);
        }

        // 根据条件分发信用点
        if (!batched || deltaCredit >= totalLiquidity.mul(swapDeltaBP).div(BP_DENOMINATOR)) {
            _delta(defaultSwapMode);
        }

        emit Swap(_dstChainId, _dstPoolId, _from, s.amount, s.eqReward, s.eqFee, s.protocolFee, s.lpFee);
        return s;
    }

    // 向远程链发送信用点
    function sendCredits(uint16 _dstChainId, uint256 _dstPoolId) external nonReentrant onlyRouter returns (CreditObj memory c) {
        ChainPath storage cp = getAndCheckCP(_dstChainId, _dstPoolId);
        // 检查远程链路是否准备就绪
        require(cp.ready == true, "Stargate: counter chainPath is not ready");
        // 将credits添加到远程链上的余额
        cp.lkb = cp.lkb.add(cp.credits);
        c.idealBalance = totalLiquidity.mul(cp.weight).div(totalWeight);
        c.credits = cp.credits;
        cp.credits = 0;
        emit SendCredits(_dstChainId, _dstPoolId, c.credits, c.idealBalance);
    }

    // 从远程链上兑换信用点
    function redeemRemote(
        uint16 _dstChainId,
        uint256 _dstPoolId,
        address _from,
        uint256 _amountLP
    ) external nonReentrant onlyRouter {
        require(_from != address(0x0), "Stargate: _from cannot be 0x0");
        uint256 amountSD = _burnLocal(_from, _amountLP);
        // 运行delta
        if (!batched || deltaCredit > totalLiquidity.mul(lpDeltaBP).div(BP_DENOMINATOR)) {
            _delta(defaultLPMode);
        }
        uint256 amountLD = amountSDtoLD(amountSD);
        emit RedeemRemote(_dstChainId, _dstPoolId, _from, _amountLP, amountLD);
    }

    // 在本地链上立即兑换信用点
    function instantRedeemLocal(
        address _from,
        uint256 _amountLP,
        address _to
    ) external nonReentrant onlyRouter returns (uint256 amountSD) {
        require(_from != address(0x0), "Stargate: _from cannot be 0x0");
        // 获取deltaCredit的值（用于优化）
        uint256 _deltaCredit = deltaCredit; 
        // 计算最大可兑换的代币数量
        uint256 _capAmountLP = _amountSDtoLP(_deltaCredit);

        if (_amountLP > _capAmountLP) _amountLP = _capAmountLP;

        // 在本地链上销毁代币并更新deltaCredit的值
        amountSD = _burnLocal(_from, _amountLP);
        deltaCredit = _deltaCredit.sub(amountSD);
        uint256 amountLD = amountSDtoLD(amountSD);
        _safeTransfer(token, _to, amountLD);
        emit InstantRedeemLocal(_from, _amountLP, amountSD, _to);
    }

    // 在本地链和远程链之间兑换信用点
    function redeemLocal(
        address _from,
        uint256 _amountLP,
        uint16 _dstChainId,
        uint256 _dstPoolId,
        bytes calldata _to
    ) external nonReentrant onlyRouter returns (uint256 amountSD) {
        require(_from != address(0x0), "Stargate: _from cannot be 0x0");

        // 检查远程链路是否准备就绪
        require(chainPaths[chainPathIndexLookup[_dstChainId][_dstPoolId]].ready == true, "Stargate: counter chainPath is not ready");
        amountSD = _burnLocal(_from, _amountLP);

        // 运行delta
        if (!batched || deltaCredit > totalLiquidity.mul(lpDeltaBP).div(BP_DENOMINATOR)) {
            _delta(false);
        }
        emit RedeemLocal(_from, _amountLP, amountSD, _dstChainId, _dstPoolId, _to);
    }

    // 在远程链上记录信用点信息
    function creditChainPath(
        uint16 _dstChainId,
        uint256 _dstPoolId,
        CreditObj memory _c
    ) external nonReentrant onlyRouter {
        ChainPath storage cp = chainPaths[chainPathIndexLookup[_dstChainId][_dstPoolId]];
        // 将信用点添加到远程链的余额中
        cp.balance = cp.balance.add(_c.credits);
        // 如果理想余额不同，则进行更新
        if (cp.idealBalance != _c.idealBalance) {
            cp.idealBalance = _c.idealBalance;
        }
        emit CreditChainPath(_dstChainId, _dstPoolId, _c.credits, _c.idealBalance);
    }

    // Local                                    Remote
    // -------                                  ---------
    // swap             ->                      swapRemote
    function swapRemote(
        uint16 _srcChainId, // 源链的ID
        uint256 _srcPoolId, // 源池的ID
        address _to, // 接收资产的地址
        SwapObj memory _s // SwapObj结构体参数
    ) external nonReentrant onlyRouter returns (uint256 amountLD) {
        // booking lpFee
        totalLiquidity = totalLiquidity.add(_s.lpFee); // 增加lpFee到总流动性
        // booking eqFee
        eqFeePool = eqFeePool.add(_s.eqFee); // 增加eqFee到eqFeePool
        // booking stargateFee
        protocolFeeBalance = protocolFeeBalance.add(_s.protocolFee); // 增加protocolFee到protocolFeeBalance

        // update LKB
        uint256 chainPathIndex = chainPathIndexLookup[_srcChainId][_srcPoolId]; // 获取源链和源池的索引
        chainPaths[chainPathIndex].lkb = chainPaths[chainPathIndex].lkb.sub(_s.lkbRemove); // 更新LKB（流动性余额）

        // user receives the amount + the srcReward
        amountLD = amountSDtoLD(_s.amount.add(_s.eqReward)); // 计算接收到的资产数量（以LD为单位）
        _safeTransfer(token, _to, amountLD); // 将资产转移给接收地址
        emit SwapRemote(_to, _s.amount.add(_s.eqReward), _s.protocolFee, _s.eqFee); // 触发SwapRemote事件
    }

    // Local                                    Remote
    // -------                                  ---------
    // redeemLocal   ->                         redeemLocalCheckOnRemote
    // redeemLocalCallback             <-
    function redeemLocalCallback(
        uint16 _srcChainId, // 源链的ID
        uint256 _srcPoolId, // 源池的ID
        address _to, // 接收资产的地址
        uint256 _amountSD, // 交换的资产数量（以SD为单位）
        uint256 _amountToMintSD // 铸造的资产数量（以SD为单位）
    ) external nonReentrant onlyRouter {
        if (_amountToMintSD > 0) {
            _mintLocal(_to, amountSDtoLD(_amountToMintSD), false, false); // 铸造资产（以LD为单位）并发送给接收地址
        }

        ChainPath storage cp = getAndCheckCP(_srcChainId, _srcPoolId); // 获取并检查链路径
        cp.lkb = cp.lkb.sub(_amountSD); // 更新LKB（流动性余额）

        uint256 amountLD = amountSDtoLD(_amountSD); // 将资产数量转换为LD单位
        _safeTransfer(token, _to, amountLD); // 将资产转移给接收地址
        emit RedeemLocalCallback(_to, _amountSD, _amountToMintSD); // 触发RedeemLocalCallback事件
    }

    // Local                                    Remote
    // -------                                  ---------
    // redeemLocal(amount)   ->               redeemLocalCheckOnRemote
    // redeemLocalCallback             <-
    function redeemLocalCheckOnRemote(
        uint16 _srcChainId, // 源链的ID
        uint256 _srcPoolId, // 源池的ID
        uint256 _amountSD // 需要兑换的资产数量（以SD为单位）
    ) external nonReentrant onlyRouter returns (uint256 swapAmount, uint256 mintAmount) {
        ChainPath storage cp = getAndCheckCP(_srcChainId, _srcPoolId); // 获取并检查链路径
        if (_amountSD > cp.balance) { // 如果需要兑换的资产数量大于链路径上的余额
            mintAmount = _amountSD - cp.balance; // 计算需要铸造的资产数量（以SD为单位）
            swapAmount = cp.balance; // 设置交换的资产数量为链路径上的余额
            cp.balance = 0; // 清空链路径上的余额
        } else {
            cp.balance = cp.balance.sub(_amountSD); // 更新链路径上的余额
            swapAmount = _amountSD; // 设置交换的资产数量为需求的资产数量
            mintAmount = 0; // 铸造的资产数量为0
        }
        emit WithdrawRemote(_srcChainId, _srcPoolId, swapAmount, mintAmount); // 触发WithdrawRemote事件
    }


    //---------------------------------------------------------------------------
    // DAO Calls
    function createChainPath(
        uint16 _dstChainId,
        uint256 _dstPoolId,
        uint256 _weight
    ) external onlyRouter {
        // 检查该链路径是否已存在，如果存在则抛出异常
        for (uint256 i = 0; i < chainPaths.length; ++i) {
            ChainPath memory cp = chainPaths[i];
            bool exists = cp.dstChainId == _dstChainId && cp.dstPoolId == _dstPoolId;
            require(!exists, "Stargate: cant createChainPath of existing dstChainId and _dstPoolId");
        }
        // 添加新的链路径，并更新总权重和索引表
        totalWeight = totalWeight.add(_weight);
        chainPathIndexLookup[_dstChainId][_dstPoolId] = chainPaths.length;
        chainPaths.push(ChainPath(false, _dstChainId, _dstPoolId, _weight, 0, 0, 0, 0));
        // 触发事件
        emit ChainPathUpdate(_dstChainId, _dstPoolId, _weight);
    }

    // 设置链路径的权重
    function setWeightForChainPath(
        uint16 _dstChainId,  // 目标链的ID
        uint256 _dstPoolId,  // 目标池子的ID
        uint16 _weight       // 链路径的权重
    ) external onlyRouter {
        // 获取并检查链路径的引用
        ChainPath storage cp = getAndCheckCP(_dstChainId, _dstPoolId);
        // 更新总权重
        totalWeight = totalWeight.sub(cp.weight).add(_weight);
        // 更新链路径的权重字段
        cp.weight = _weight;
        // 触发事件，传递更新后的链路径信息
        emit ChainPathUpdate(_dstChainId, _dstPoolId, _weight);
    }

    // 设置桥接手续费
    function setFee(uint256 _mintFeeBP) external onlyRouter {
        require(_mintFeeBP <= BP_DENOMINATOR, "Bridge: cum fees > 100%");
        // 将桥接手续费赋值给铸币手续费
        mintFeeBP = _mintFeeBP;
        // 触发事件，传递更新后的手续费信息
        emit FeesUpdated(mintFeeBP);
    }

    // 设置费用相关的库合约地址
    function setFeeLibrary(address _feeLibraryAddr) external onlyRouter {
        require(_feeLibraryAddr != address(0x0), "Stargate: fee library cant be 0x0");
        // 将地址赋值给费用相关的库合约地址
        feeLibrary = _feeLibraryAddr;
        // 触发事件，传递更新后的库合约地址
        emit FeeLibraryUpdated(_feeLibraryAddr);
    }

    // 设置交换停止状态
    function setSwapStop(bool _swapStop) external onlyRouter {
        // 设置交换停止状态
        stopSwap = _swapStop;
        // 触发事件，传递更新后的交换停止状态
        emit StopSwapUpdated(_swapStop);
    }

    // 设置交易和LP手续费计算参数
    function setDeltaParam(
        bool _batched,                    // 是否批量处理
        uint256 _swapDeltaBP,              // 交易手续费BP
        uint256 _lpDeltaBP,                // LP手续费BP
        bool _defaultSwapMode,             // 默认交易模式
        bool _defaultLPMode                // 默认LP模式
    ) external onlyRouter {
        require(_swapDeltaBP <= BP_DENOMINATOR && _lpDeltaBP <= BP_DENOMINATOR, "Stargate: wrong Delta param");
        // 更新配置变量
        batched = _batched;
        swapDeltaBP = _swapDeltaBP;
        lpDeltaBP = _lpDeltaBP;
        defaultSwapMode = _defaultSwapMode;
        defaultLPMode = _defaultLPMode;
        // 触发事件，传递更新后的参数信息
        emit DeltaParamUpdated(_batched, _swapDeltaBP, _lpDeltaBP, _defaultSwapMode, _defaultLPMode);
    }

    // 调用_delta函数
    function callDelta(bool _fullMode) external onlyRouter {
        // _delta函数可能执行一些与交易执行相关的操作
        _delta(_fullMode);
    }

    // 激活链路径
    function activateChainPath(uint16 _dstChainId, uint256 _dstPoolId) external onlyRouter {
        // 获取并检查链路径的引用
        ChainPath storage cp = getAndCheckCP(_dstChainId, _dstPoolId);
        require(cp.ready == false, "Stargate: chainPath is already active");
        // 设置链路径为已激活状态
        cp.ready = true;
    }

    // 提取协议费用余额
    function withdrawProtocolFeeBalance(address _to) external onlyRouter {
        if (protocolFeeBalance > 0) {
            // 将协议费用余额转换为LD代币数量
            uint256 amountOfLD = amountSDtoLD(protocolFeeBalance);
            // 清空协议费用余额
            protocolFeeBalance = 0;
            // 将LD代币转账给指定地址
            _safeTransfer(token, _to, amountOfLD);
            // 触发事件，传递提取的LD代币数量和目标地址信息
            emit WithdrawProtocolFeeBalance(_to, amountOfLD);
        }
    }


    function withdrawMintFeeBalance(address _to) external onlyRouter {
        if (mintFeeBalance > 0) {   // 如果铸币手续费余额大于零
            // 将铸币手续费余额转换为LD代币数量
            uint256 amountOfLD = amountSDtoLD(mintFeeBalance);
            // 清空铸币手续费余额
            mintFeeBalance = 0;
            // 将LD代币转账给指定地址
            _safeTransfer(token, _to, amountOfLD);
            // 触发事件，传递转账信息
            emit WithdrawMintFeeBalance(_to, amountOfLD);
        }
    }

    //---------------------------------------------------------------------------
    // INTERNAL
    // Conversion Helpers
    //---------------------------------------------------------------------------
    // 将LP代币的数量转换为LD代币的数量
    function amountLPtoLD(uint256 _amountLP) external view returns (uint256) {
        // 调用内部函数 _amountLPtoSD 将LP代币数量转换为SD代币数量，再调用 amountSDtoLD 将SD代币数量转换为LD代币数量
        return amountSDtoLD(_amountLPtoSD(_amountLP));
    }

    // 将LP代币的数量转换为SD代币的数量
    function _amountLPtoSD(uint256 _amountLP) internal view returns (uint256) {
        // 确保总供应量 totalSupply 大于零，避免除零错误
        require(totalSupply > 0, "Stargate: cant convert LPtoSD when totalSupply == 0");
        // 计算出 _amountLP 对应的 SD 代币数量，并返回结果
        return _amountLP.mul(totalLiquidity).div(totalSupply);
    }

    // 将SD代币的数量转换为LP代币的数量
    function _amountSDtoLP(uint256 _amountSD) internal view returns (uint256) {
        // 确保总流动性 totalLiquidity 大于零，避免除零错误
        require(totalLiquidity > 0, "Stargate: cant convert SDtoLP when totalLiq == 0");
        // 计算出 _amountSD 对应的 LP 代币数量，并返回结果
        return _amountSD.mul(totalSupply).div(totalLiquidity);
    }

    // 将SD代币的数量转换为LD代币的数量
    function amountSDtoLD(uint256 _amount) internal view returns (uint256) {
        // 将 _amount 乘以转换率 convertRate，返回结果
        return _amount.mul(convertRate);
    }

    // 将LD代币的数量转换为SD代币的数量
    function amountLDtoSD(uint256 _amount) internal view returns (uint256) {
        // 将 _amount 除以转换率 convertRate，返回结果
        return _amount.div(convertRate);
    }

    // 获取并验证目标链路
    function getAndCheckCP(uint16 _dstChainId, uint256 _dstPoolId) internal view returns (ChainPath storage) {
        // 确保链路数组 chainPaths 中存在链路，避免索引越界
        require(chainPaths.length > 0, "Stargate: no chainpaths exist");
        // 从链路数组 chainPaths 中查找目标链路，并确保链路存在并匹配目标链路，否则抛出异常
        ChainPath storage cp = chainPaths[chainPathIndexLookup[_dstChainId][_dstPoolId]];
        require(cp.dstChainId == _dstChainId && cp.dstPoolId == _dstPoolId, "Stargate: local chainPath does not exist");
        // 返回目标链路信息
        return cp;
    }

    // 获取目标链路
    function getChainPath(uint16 _dstChainId, uint256 _dstPoolId) external view returns (ChainPath memory) {
        // 从链路数组 chainPaths 中查找目标链路，并确保链路存在并匹配目标链路，否则抛出异常
        ChainPath memory cp = chainPaths[chainPathIndexLookup[_dstChainId][_dstPoolId]];
        require(cp.dstChainId == _dstChainId && cp.dstPoolId == _dstPoolId, "Stargate: local chainPath does not exist");
        // 返回目标链路信息
        return cp;
    }

    // 烧毁本地 LP 代币，并返回对应的 SD 代币数量
    function _burnLocal(address _from, uint256 _amountLP) internal returns (uint256) {
        // 确保总供应量 totalSupply 大于零，避免除零错误
        require(totalSupply > 0, "Stargate: cant burn when totalSupply == 0");
        // 获取烧毁账户 _from 的 LP 代币余额，并确保余额充足，否则抛出异常
        uint256 amountOfLPTokens = balanceOf[_from];
        require(amountOfLPTokens >= _amountLP, "Stargate: not enough LP tokens to burn");
        // 根据 _amountLP 计算对应的 SD 代币数量，在总流动性 totalLiquidity 中减去相应数量的 SD 代币
        uint256 amountSD = _amountLP.mul(totalLiquidity).div(totalSupply);
        totalLiquidity = totalLiquidity.sub(amountSD);
        // 调用 _burn 函数，烧毁指定账户的 LP 代币 _amountLP
        _burn(_from, _amountLP);
        // 触发 Burn 事件，记录烧毁信息
        emit Burn(_from, _amountLP, amountSD);
        // 返回对应的 SD 代币数量
        return amountSD;
    }

    // 处理链路径的delta credit（差额信用额度），以实现链路径之间的权重平衡
    function _delta(bool fullMode) internal {
        // 判断deltaCredit和totalWeight是否大于0
        if (deltaCredit > 0 && totalWeight > 0) {
            uint256 cpLength = chainPaths.length;
            // 创建一个长度为cpLength的数组deficit，用于存储各条链路径的差异
            uint256[] memory deficit = new uint256[](cpLength);
            uint256 totalDeficit = 0;

            // 算法步骤6-9：计算到达平衡状态所需的总量和金额
            for (uint256 i = 0; i < cpLength; ++i) {
                ChainPath storage cp = chainPaths[i];
                // 计算每个链路径需要的流动性，并据此计算出当前的流动性
                uint256 balLiq = totalLiquidity.mul(cp.weight).div(totalWeight);
                uint256 currLiq = cp.lkb.add(cp.credits);
                if (balLiq > currLiq) {
                    // 如果balLiq > currLiq，则表示该链路径需要额外的差额信用额度
                    deficit[i] = balLiq - currLiq;
                    totalDeficit = totalDeficit.add(deficit[i]);
                }
            }

            // 表示分配多少delta credit
            uint256 spent;

            // 如果totalDeficit等于0，在fullMode情况下执行全部分配
            if (totalDeficit == 0) {
                // 只有fullMode下才分配额外信用额度
                if (fullMode && deltaCredit > 0) {
                    // 按权重为链路径分配信用额度
                    for (uint256 i = 0; i < cpLength; ++i) {
                        ChainPath storage cp = chainPaths[i];
                        // 将信用额度增加到BalanceChange的金额，并根据权重分配剩余的信用额度
                        uint256 amtToCredit = deltaCredit.mul(cp.weight).div(totalWeight);
                        spent = spent.add(amtToCredit);
                        cp.credits = cp.credits.add(amtToCredit);
                    }
                } // 否则不执行任何操作
            } else if (totalDeficit <= deltaCredit) {
                if (fullMode) {
                    // 算法步骤13：计算使各链路径达到平衡状态的额度
                    uint256 excessCredit = deltaCredit - totalDeficit;
                    // 算法步骤14-16：计算信用额度
                    for (uint256 i = 0; i < cpLength; ++i) {
                        if (deficit[i] > 0) {
                            ChainPath storage cp = chainPaths[i];
                            // 将额外的信用额度增加到BalanceChange的金额，并根据权重分配剩余的信用额度
                            uint256 amtToCredit = deficit[i].add(excessCredit.mul(cp.weight).div(totalWeight));
                            spent = spent.add(amtToCredit);
                            cp.credits = cp.credits.add(amtToCredit);
                        }
                    }
                } else {
                    // 如果totalDeficit <= deltaCredit 但不运行fullMode，则直接分配链路径的信用额度，而不是使用全部deltaCredit
                    for (uint256 i = 0; i < cpLength; ++i) {
                        if (deficit[i] > 0) {
                            ChainPath storage cp = chainPaths[i];
                            uint256 amtToCredit = deficit[i];
                            spent = spent.add(amtToCredit);
                            cp.credits = cp.credits.add(amtToCredit);
                        }
                    }
                }
            } else {
                // 如果totalDeficit > deltaCredit，则正常化差额（即按比例分配）
                for (uint256 i = 0; i < cpLength; ++i) {
                    if (deficit[i] > 0) {
                        ChainPath storage cp = chainPaths[i];
                        uint256 proportionalDeficit = deficit[i].mul(deltaCredit).div(totalDeficit);
                        spent = spent.add(proportionalDeficit);
                        cp.credits = cp.credits.add(proportionalDeficit);
                    }
                }
            }

            // 划分完信用额度后，需要从deltaCredit中扣除已经分配的信用额度
            deltaCredit = deltaCredit.sub(spent);
        }
    }

    // 创造新的local LP Token，同时处理相关的参数
    function _mintLocal(address _to, uint256 _amountLD, bool _feesEnabled, bool _creditDelta) internal returns (uint256 amountSD) {
        require(totalWeight > 0, "Stargate: No ChainPaths exist");
        amountSD = amountLDtoSD(_amountLD);

        uint256 mintFeeSD = 0;
        if (_feesEnabled) {
            // 计算铸币费用，将其扣除
            mintFeeSD = amountSD.mul(mintFeeBP).div(BP_DENOMINATOR);
            amountSD = amountSD.sub(mintFeeSD);
            mintFeeBalance = mintFeeBalance.add(mintFeeSD);
        }

        if (_creditDelta) {
            // 增加deltaCredit
            deltaCredit = deltaCredit.add(amountSD);
        }

        uint256 amountLPTokens = amountSD;
        if (totalSupply != 0) {
            amountLPTokens = amountSD.mul(totalSupply).div(totalLiquidity);
        }
        totalLiquidity = totalLiquidity.add(amountSD);

        // 将新的local LP Tokens分配给用户
        _mint(_to, amountLPTokens);
        emit Mint(_to, amountLPTokens, amountSD, mintFeeSD);

        // 如果deltaCredit需要被处理，则对其进行处理
        if (!batched || deltaCredit > totalLiquidity.mul(lpDeltaBP).div(BP_DENOMINATOR)) {
            _delta(defaultLPMode);
        }
    }

    // 安全地将代币转移给指定地址
    function _safeTransfer(address _token, address _to, uint256 _value) private {
        // 调用代币合约的转账方法
        (bool success, bytes memory data) = _token.call(abi.encodeWithSelector(SELECTOR, _to, _value));
        require(success && (data.length == 0 || abi.decode(data, (bool))), "Stargate: TRANSFER_FAILED");
    }
}