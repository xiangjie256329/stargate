// SPDX-License-Identifier: BUSL-1.1

pragma solidity 0.7.6;

// libraries
import "@openzeppelin/contracts/math/SafeMath.sol";

contract LPTokenERC20 {
    using SafeMath for uint256; // 使用SafeMath库处理数值计算，以避免溢出和下溢错误。

    //---------------------------------------------------------------------------
    // CONSTANTS
    string public name; // 代币名称
    string public symbol; // 代币符号
    bytes32 public constant PERMIT_TYPEHASH = 0x6e71edae12b1b97f4d1f60370fef10105fa2faae0126114a169c64845d6126c9; // 用于签名验证的常量
    // set in constructor
    bytes32 public DOMAIN_SEPARATOR; // 域分隔符，用于在执行代币转账时验证签名的有效性。

    //---------------------------------------------------------------------------
    // VARIABLES
    uint256 public decimals; // 代币小数位数
    uint256 public totalSupply; // 代币总供应量
    mapping(address => uint256) public balanceOf; // 地址余额映射表
    mapping(address => mapping(address => uint256)) public allowance; // 地址授权额度映射表
    mapping(address => uint256) public nonces; // 地址用于签署授权交易的nonce值映射表

    //---------------------------------------------------------------------------
    // EVENTS
    event Approval(address indexed owner, address indexed spender, uint256 value); // 授权事件
    event Transfer(address indexed from, address indexed to, uint256 value); // 转账事件

    constructor(string memory _name, string memory _symbol) {
        name = _name;
        symbol = _symbol;
        uint256 chainId;
        assembly {
            chainId := chainid() // 获取当前的链ID
        }
        DOMAIN_SEPARATOR = keccak256( // 生成域分隔符，用于在执行代币转账时验证签名的有效性。
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256(bytes(name)),
                keccak256(bytes("1")),
                chainId,
                address(this)
            )
        );
    }

    function _mint(address to, uint256 value) internal {
        totalSupply = totalSupply.add(value); // 增加总供应量
        balanceOf[to] = balanceOf[to].add(value); // 增加地址余额
        emit Transfer(address(0), to, value); // 触发转账事件
    }

    function _burn(address from, uint256 value) internal {
        balanceOf[from] = balanceOf[from].sub(value); // 减少地址余额
        totalSupply = totalSupply.sub(value); // 减少总供应量
        emit Transfer(from, address(0), value); // 触发转账事件
    }

    function _approve(
        address owner,
        address spender,
        uint256 value
    ) private {
        allowance[owner][spender] = value; // 更新授权额度
        emit Approval(owner, spender, value); // 触发授权事件
    }

    function _transfer(
        address from,
        address to,
        uint256 value
    ) private {
        balanceOf[from] = balanceOf[from].sub(value); // 减少发送地址余额
        balanceOf[to] = balanceOf[to].add(value); // 增加接收地址余额
        emit Transfer(from, to, value); // 触发转账事件
    }

    function approve(address spender, uint256 value) external returns (bool) {
        _approve(msg.sender, spender, value); // 执行授权操作
        return true;
    }

    function transfer(address to, uint256 value) external returns (bool) {
        _transfer(msg.sender, to, value); // 执行转账操作
        return true;
    }

    function transferFrom(
        address from,
        address to,
        uint256 value
    ) external returns (bool) {
        if (allowance[from][msg.sender] != uint256(-1)) { // 如果授权额度不是无限（-1）
            allowance[from][msg.sender] = allowance[from][msg.sender].sub(value); // 减少授权额度
        }
        _transfer(from, to, value); // 执行转账操作
        return true;
    }

    function increaseAllowance(address spender, uint256 addedValue) public virtual returns (bool) {
        _approve(msg.sender, spender, allowance[msg.sender][spender].add(addedValue)); // 增加授权额度
        return true;
    }

    function decreaseAllowance(address spender, uint256 subtractedValue) public virtual returns (bool) {
        _approve(msg.sender, spender, allowance[msg.sender][spender].sub(subtractedValue, "ERC20: decreased allowance below zero")); // 减少授权额度
        return true;
    }

    function permit(
        address owner,
        address spender,
        uint256 value,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external {
        require(deadline >= block.timestamp, "Bridge: EXPIRED"); // 确认授权有效性
        bytes32 digest = keccak256( // 计算签名哈希值
            abi.encodePacked(
                "\x19\x01",
                DOMAIN_SEPARATOR,
                keccak256(abi.encode(PERMIT_TYPEHASH, owner, spender, value, nonces[owner]++, deadline))
            )
        );
        address recoveredAddress = ecrecover(digest, v, r, s); // 获取签名地址
        require(recoveredAddress != address(0) && recoveredAddress == owner, "Bridge: INVALID_SIGNATURE"); // 确认签名地址有效性
        _approve(owner, spender, value); // 执行授权操作
    }
}
