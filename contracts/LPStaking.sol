// SPDX-License-Identifier: BUSL-1.1

pragma solidity 0.7.6;

// imports
import "@openzeppelin/contracts/utils/EnumerableSet.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "./StargateToken.sol";

// interfaces
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

// libraries
import "@openzeppelin/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";

//这是一个LP质押合约，用于用户锁定LP Token并获取STG代币奖励。合约会根据每个池子的权重，定期发放一定数量的STG代币给池子中锁定了LP Token的用户，
//发放数量和频率可以通过调整参数进行控制。LP Token可以通过add函数添加新的池子，也可以通过set函数修改现有池子的权重。
//用户可以通过deposit、withdraw、emergencyWithdraw等函数将LP Token质押进池子中并进行相关操作。
//除此之外，还有一些安全性的处理，例如safeStargateTransfer函数，用以处理转账时的额外细节。
contract LPStaking is Ownable {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    // Info of each user.
    struct UserInfo {
        uint256 amount; // 用户质押的LP Token数量
        uint256 rewardDebt; // 奖励债务
        // 在这里进行一些特殊的数学运算。主要是在任何时间点上，用户应获得但尚未分配的奖励数量为：
        //   待分配奖励 = (用户质押数量 * 池子的奖励累计 / LP Token累计)
        // 当用户存入或提取LP Token时，会发生以下情况：
        //   1. 更新池子的`奖励累计` (pool.accStargatePerShare) 和 `最新奖励块号` (pool.lastRewardBlock)
        //   2. 向用户地址发送待分配奖励
        //   3. 更新用户的质押数量 (user.amount)
        //   4. 更新用户的奖励债务 (user.rewardDebt)
    }

    // Info of each pool.
    struct PoolInfo {
        IERC20 lpToken; // LP Token合约地址
        uint256 allocPoint; // 分配给该池子的奖励点数。每个块要分发的STG代币数量。
        uint256 lastRewardBlock; // 发放奖励的最后一个块号
        uint256 accStargatePerShare; // STG代币累积奖励，乘以1e12。具体请参考下面的说明。
    }

    // STG代币合约
    StargateToken public stargate;
    // 奖励结束的块号
    uint256 public bonusEndBlock;
    // 每个块要创建的STG代币数量
    uint256 public stargatePerBlock;
    // 早期STG代币制造商的奖励倍增器
    uint256 public constant BONUS_MULTIPLIER = 1;
    // 追踪已添加的代币
    mapping(address => bool) private addedLPTokens;

    mapping(uint256 => uint256) public lpBalances; // 每个池子的LP Token余额

    // 存储每个池子的信息
    PoolInfo[] public poolInfo;
    // 存储质押用户的信息
    mapping(uint256 => mapping(address => UserInfo)) public userInfo;
    // 总的奖励点数，必须等于所有池子中的奖励点数之和。
    uint256 public totalAllocPoint = 0;
    // STG代币开始挖矿的块号
    uint256 public startBlock;

    event Deposit(address indexed user, uint256 indexed pid, uint256 amount); // 存入LP Token
    event Withdraw(address indexed user, uint256 indexed pid, uint256 amount); // 提取LP Token
    event EmergencyWithdraw(address indexed user, uint256 indexed pid, uint256 amount); // 紧急提取LP Token

    constructor(
        StargateToken _stargate,
        uint256 _stargatePerBlock,
        uint256 _startBlock,
        uint256 _bonusEndBlock
    ) {
        require(_startBlock >= block.number, "LPStaking: _startBlock must be >= current block");
        require(_bonusEndBlock >= _startBlock, "LPStaking: _bonusEndBlock must be > than _startBlock");
        require(address(_stargate) != address(0x0), "Stargate: _stargate cannot be 0x0");

        stargate = _stargate;
        stargatePerBlock = _stargatePerBlock;
        startBlock = _startBlock;
        bonusEndBlock = _bonusEndBlock;
    }

    function poolLength() external view returns (uint256) {
        return poolInfo.length; // 返回池子的数量
    }

    // 添加新的LP Token（只能由合约所有者调用）
    function add(uint256 _allocPoint, IERC20 _lpToken) public onlyOwner {
        massUpdatePools();
        require(address(_lpToken) != address(0x0), "StarGate: lpToken cant be 0x0");
        require(addedLPTokens[address(_lpToken)] == false, "StarGate: _lpToken already exists");

        addedLPTokens[address(_lpToken)] = true;
        uint256 lastRewardBlock = block.number > startBlock ? block.number : startBlock;

        totalAllocPoint = totalAllocPoint.add(_allocPoint);
        poolInfo.push(PoolInfo({lpToken: _lpToken, allocPoint: _allocPoint, lastRewardBlock: lastRewardBlock, accStargatePerShare: 0}));
    }

    // 设置池子的奖励点数
    function set(uint256 _pid, uint256 _allocPoint) public onlyOwner {
        massUpdatePools();

        totalAllocPoint = totalAllocPoint.sub(poolInfo[_pid].allocPoint).add(_allocPoint);
        poolInfo[_pid].allocPoint = _allocPoint;
    }

    // 获取奖励倍增数
    function getMultiplier(uint256 _from, uint256 _to) public view returns (uint256) {
        if (_to <= bonusEndBlock) {
            return _to.sub(_from).mul(BONUS_MULTIPLIER);
        } else if (_from >= bonusEndBlock) {
            return _to.sub(_from);
        } else {
            return bonusEndBlock.sub(_from).mul(BONUS_MULTIPLIER).add(_to.sub(bonusEndBlock));
        }
    }

    //返回指定用户在指定挖矿池中待领取的奖励数量
    function pendingStargate(uint256 _pid, address _user) external view returns (uint256) {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][_user];
        uint256 accStargatePerShare = pool.accStargatePerShare;
        uint256 lpSupply = pool.lpToken.balanceOf(address(this));
        if (block.number > pool.lastRewardBlock && lpSupply != 0) {
            uint256 multiplier = getMultiplier(pool.lastRewardBlock, block.number);
            uint256 stargateReward = multiplier.mul(stargatePerBlock).mul(pool.allocPoint).div(totalAllocPoint);
            accStargatePerShare = accStargatePerShare.add(stargateReward.mul(1e12).div(lpSupply));
        }
        return user.amount.mul(accStargatePerShare).div(1e12).sub(user.rewardDebt);
    }

    //批量更新所有挖矿池的奖励情况
    function massUpdatePools() public {
        uint256 length = poolInfo.length;
        for (uint256 pid = 0; pid < length; ++pid) {
            updatePool(pid);
        }
    }

    //更新指定挖矿池的奖励情况
    function updatePool(uint256 _pid) public {
        PoolInfo storage pool = poolInfo[_pid];
        if (block.number <= pool.lastRewardBlock) {
            return;
        }
        uint256 lpSupply = pool.lpToken.balanceOf(address(this));
        if (lpSupply == 0) {
            pool.lastRewardBlock = block.number;
            return;
        }
        uint256 multiplier = getMultiplier(pool.lastRewardBlock, block.number);
        uint256 stargateReward = multiplier.mul(stargatePerBlock).mul(pool.allocPoint).div(totalAllocPoint);

        pool.accStargatePerShare = pool.accStargatePerShare.add(stargateReward.mul(1e12).div(lpSupply));
        pool.lastRewardBlock = block.number;
    }

    //用户向指定挖矿池存入指定数量的资金，并计算并领取之前存款所积累的奖励
    function deposit(uint256 _pid, uint256 _amount) public {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];
        updatePool(_pid);
        if (user.amount > 0) {
            uint256 pending = user.amount.mul(pool.accStargatePerShare).div(1e12).sub(user.rewardDebt);
            safeStargateTransfer(msg.sender, pending);
        }
        pool.lpToken.safeTransferFrom(address(msg.sender), address(this), _amount);
        user.amount = user.amount.add(_amount);
        user.rewardDebt = user.amount.mul(pool.accStargatePerShare).div(1e12);
        lpBalances[_pid] = lpBalances[_pid].add(_amount);
        emit Deposit(msg.sender, _pid, _amount);
    }

    //用户从指定挖矿池中提取指定数量的资金，并计算并领取之前存款所积累的奖励
    function withdraw(uint256 _pid, uint256 _amount) public {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];
        require(user.amount >= _amount, "withdraw: _amount is too large");
        updatePool(_pid);
        uint256 pending = user.amount.mul(pool.accStargatePerShare).div(1e12).sub(user.rewardDebt);
        safeStargateTransfer(msg.sender, pending);
        user.amount = user.amount.sub(_amount);
        user.rewardDebt = user.amount.mul(pool.accStargatePerShare).div(1e12);
        pool.lpToken.safeTransfer(address(msg.sender), _amount);
        lpBalances[_pid] = lpBalances[_pid].sub(_amount);
        emit Withdraw(msg.sender, _pid, _amount);
    }

    /// @notice Withdraw without caring about rewards.
    /// @param _pid The pid specifies the pool
    // 用户紧急提取指定挖矿池中的所有资金，无需关心奖励
    function emergencyWithdraw(uint256 _pid) public {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];
        uint256 userAmount = user.amount;
        user.amount = 0;
        user.rewardDebt = 0;
        pool.lpToken.safeTransfer(address(msg.sender), userAmount);
        lpBalances[_pid] = lpBalances[_pid].sub(userAmount);
        emit EmergencyWithdraw(msg.sender, _pid, userAmount);
    }

    /// @notice Safe transfer function, just in case if rounding error causes pool to not have enough STGs.
    /// @param _to The address to transfer tokens to
    /// @param _amount The quantity to transfer
    // 安全的转账函数，用于将奖励发放给用户。如果奖励数量大于合约当前持有的STG代币数量，会转移全部持有的STG代币；否则，只转移指定数量的STG代币。
    function safeStargateTransfer(address _to, uint256 _amount) internal {
        uint256 stargateBal = stargate.balanceOf(address(this));
        if (_amount > stargateBal) {
            IERC20(stargate).safeTransfer(_to, stargateBal);
        } else {
            IERC20(stargate).safeTransfer(_to, _amount);
        }
    }

    // 设置每个区块产生的STG奖励数量，并批量更新所有挖矿池的奖励情况
    function setStargatePerBlock(uint256 _stargatePerBlock) external onlyOwner {
        massUpdatePools();
        stargatePerBlock = _stargatePerBlock;
    }

    // Override the renounce ownership inherited by zeppelin ownable
    // 重写了合约的renounceOwnership函数，使其只能由合约的拥有者调用
    function renounceOwnership() public override onlyOwner {}
}
