// SPDX-License-Identifier: BUSL-1.1

pragma solidity 0.7.6;
pragma abicoder v2;

import "../interfaces/IStargateReceiver.sol";
import "../interfaces/IStargateRouter.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import "hardhat/console.sol";

// 这段代码定义了一个名为LoopBackMock的智能合约，用于模拟Stargate Router接收器的功能。它实现了一个名为IStargateReceiver的接口，该接口定义了sgReceive函数，
// 用于接收来自Stargate Router的交易。此外，合约还包含了一个事件LoopBack，用于触发转账操作。在构造函数中，需要传入Stargate Router合约的地址，
// 该地址将被保存为不可变的公共变量router。合约还定义了一个布尔类型的变量paused，用于暂停或取消暂停接收交易的功能。主要的逻辑在sgReceive函数中实现，
// 其余部分主要是辅助性质的代码。在函数实现中，首先检查是否已经被暂停，并检查发送者是否为Router合约。然后计算交易金额的一半，并将源地址转换为动态字节数组。
// 接下来，授权Router合约花费halfAmount数量的代币，并解码交易的payload，获取源池子ID和目标池子ID。之后通过调用quoteLayerZeroFee函数估算Layer 0手续费，
// 并向Router合约发送原生代币作为交易手续费，以确保交易可以顺利进行。最后，触发LoopBack事件，将源地址、源池子ID、目标池子ID和交易金额的一半作为参数。
// 除此之外，合约还定义了一个名为pause的函数，用于暂停或取消暂停接收交易的功能。最后，定义了fallback函数和receive函数，以便能够接收ETH转账。
contract LoopBackMock is IStargateReceiver {
    // 声明不可变的Stargate Router合约地址
    IStargateRouter public immutable router;
    
    // 定义LoopBack事件，用于触发交易转移的操作。
    event LoopBack(bytes srcAddress, uint256 srcPoolId, uint256 dstPoolId, uint256 amount);

    // 构造函数，接收Router合约地址
    constructor(address _router) {
        router = IStargateRouter(_router);
    }

    bool paused;

    // 实现IStargateReceiver接口的sgReceive函数，用于接收来自Router合约的交易。
    function sgReceive(
        uint16 _chainId,
        bytes memory _srcAddress,
        uint256, /*_nonce*/
        address _token,
        uint256 amountLD,
        bytes memory payload
    ) external override {
        // 确保没有被暂停
        require(!paused, "Failed sgReceive due to pause");

        // 检查发送者是否为Router地址
        require(msg.sender == address(router), "only router");

        // 计算交易金额的一半
        uint256 halfAmount = amountLD / 2;

        // 将bytes类型的源地址转换为动态字节数组
        bytes memory srcAddress = _srcAddress;

        // 授权Router花费halfAmount数量的代币
        IERC20(_token).approve(address(router), halfAmount);

        // 解码payload，获取源池子ID和目标池子ID
        (uint256 srcPoolId, uint256 dstPoolId) = abi.decode(payload, (uint256, uint256));

        // 估算Layer 0手续费
        (uint256 nativeFee, ) = router.quoteLayerZeroFee(_chainId, 1, srcAddress, "", IStargateRouter.lzTxObj(500000, 0, ""));

        // 向Router合约发送原生代币作为交易手续费
        router.swap{value: nativeFee}(
            _chainId,
            srcPoolId,
            dstPoolId,
            address(this),
            halfAmount,
            0,
            IStargateRouter.lzTxObj(500000, 0, ""),
            srcAddress, 
            bytes("0x")
        );

        // 触发LoopBack事件，将源地址、源池子ID、目标池子ID和交易金额的一半作为参数。
        emit LoopBack(srcAddress, srcPoolId, dstPoolId, halfAmount);
    }

    // 暂停或取消暂停接收交易的功能
    function pause(bool _paused) external {
        paused = _paused;
    }

    // 定义fallback函数，可以接收ETH转账
    fallback() external payable {}

    // 定义receive函数，可以接收ETH转账
    receive() external payable {}
}
