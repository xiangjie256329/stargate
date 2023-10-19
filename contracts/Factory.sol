// SPDX-License-Identifier: BUSL-1.1

pragma solidity 0.7.6;
pragma abicoder v2;

import "@openzeppelin/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "./Pool.sol";

//实现了一个工厂模式，用于创建和管理代币交易池
contract Factory is Ownable {
    using SafeMath for uint256;

    //---------------------------------------------------------------------------
    // VARIABLES
    // 将每个池的 ID 映射到对应的 Pool 合约地址
    mapping(uint256 => Pool) public getPool; // poolId -> PoolInfo
    // 保存所有池的合约地址
    address[] public allPools;
    // 指定 Router 合约的地址
    address public immutable router;
    // 用于存储获取交换费用参数的合约地址
    address public defaultFeeLibrary; // address for retrieving fee params for swaps

    //---------------------------------------------------------------------------
    // MODIFIERS
    
    modifier onlyRouter() {
        require(msg.sender == router, "Stargate: caller must be Router.");
        _;
    }

    //---------------------------------------------------------------------------
    // CONSTRUCTOR
    
    constructor(address _router) {
        require(_router != address(0x0), "Stargate: _router cant be 0x0"); // 1 time only
        router = _router;
    }

    //---------------------------------------------------------------------------
    // FUNCTIONS
    
    // 设置默认的费用计算合约地址
    function setDefaultFeeLibrary(address _defaultFeeLibrary) external onlyOwner {
        require(_defaultFeeLibrary != address(0x0), "Stargate: fee library cant be 0x0");
        defaultFeeLibrary = _defaultFeeLibrary;
    }

    // 返回所有池子的数量
    function allPoolsLength() external view returns (uint256) {
        return allPools.length;
    }

    // 创建一个新的池子
    function createPool(
        uint256 _poolId,
        address _token,
        uint8 _sharedDecimals,
        uint8 _localDecimals,
        string memory _name,
        string memory _symbol
    ) public onlyRouter returns (address poolAddress) {
        // 检查池子是否已经创建
        require(address(getPool[_poolId]) == address(0x0), "Stargate: Pool already created");

        // 创建新的池子合约
        Pool pool = new Pool(_poolId, router, _token, _sharedDecimals, _localDecimals, defaultFeeLibrary, _name, _symbol);
        
        // 将池子地址保存到映射和数组中
        getPool[_poolId] = pool;
        poolAddress = address(pool);
        allPools.push(poolAddress);
    }

    // 放弃合约所有权
    function renounceOwnership() public override onlyOwner {}
}
