// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
// FOR LOCAL FORK TESTING ONLY. Not a production router or migration contract.
struct PoolKey { address currency0; address currency1; uint24 fee; int24 tickSpacing; address hooks; }
struct ModifyLiquidityParams { int24 tickLower; int24 tickUpper; int256 liquidityDelta; bytes32 salt; }
struct SwapParams { bool zeroForOne; int256 amountSpecified; uint160 sqrtPriceLimitX96; }
interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function totalSupply() external view returns (uint256);
    function decimals() external view returns (uint8);
    function transfer(address,uint256) external returns (bool);
    function approve(address,uint256) external returns (bool);
}
interface IWETH is IERC20 { function deposit() external payable; }
interface IManager {
    function unlock(bytes calldata) external returns (bytes memory);
    function modifyLiquidity(PoolKey calldata,ModifyLiquidityParams calldata,bytes calldata) external returns (int256,int256);
    function swap(PoolKey calldata,SwapParams calldata,bytes calldata) external returns (int256);
    function sync(address) external;
    function settle() external payable returns (uint256);
    function take(address,address,uint256) external;
    function extsload(bytes32) external view returns (bytes32);
}
interface IPermit2 { function approve(address,address,uint160,uint48) external; }
interface IPositionManager {
    function nextTokenId() external view returns(uint256);
    function modifyLiquidities(bytes calldata,uint256) external payable;
}
// Full precision mulDiv follows Uniswap FullMath (MIT); see NOTICE.md.
library FM {
    function mulDiv(uint256 a,uint256 b,uint256 d) internal pure returns(uint256 z) {
        unchecked {
            uint256 p0; uint256 p1;
            assembly ("memory-safe") { let mm := mulmod(a,b,not(0)) p0 := mul(a,b) p1 := sub(sub(mm,p0),lt(mm,p0)) }
            if(p1==0) return p0/d;
            require(d>p1,"mulDiv overflow");
            uint256 r; assembly ("memory-safe") { r := mulmod(a,b,d) p1 := sub(p1,gt(r,p0)) p0 := sub(p0,r) }
            uint256 twos=(0-d)&d;
            assembly ("memory-safe") { d := div(d,twos) p0 := div(p0,twos) twos := add(div(sub(0,twos),twos),1) }
            p0 |= p1*twos;
            uint256 inv=(3*d)^2;
            inv*=2-d*inv; inv*=2-d*inv; inv*=2-d*inv;
            inv*=2-d*inv; inv*=2-d*inv; inv*=2-d*inv;
            z=p0*inv;
        }
    }
}
library TM {
    uint256 internal constant Q96=1<<96;
    uint160 internal constant MAX_SQRT=1461446703485210103287273052203988822378723970342;
    // getSqrtPriceAtTick equivalent, with the published Uniswap TickMath constants.
    function sqrtAt(int24 tick) internal pure returns(uint160) {
        require(tick>=-887272 && tick<=887272,"tick bounds");
        uint256 a=uint256(tick<0 ? -int256(tick) : int256(tick));
        uint256[20] memory f=[
            uint256(0xfffcb933bd6fad37aa2d162d1a594001),
            uint256(0xfff97272373d413259a46990580e213a),
            uint256(0xfff2e50f5f656932ef12357cf3c7fdcc),
            uint256(0xffe5caca7e10e4e61c3624eaa0941cd0),
            uint256(0xffcb9843d60f6159c9db58835c926644),
            uint256(0xff973b41fa98c081472e6896dfb254c0),
            uint256(0xff2ea16466c96a3843ec78b326b52861),
            uint256(0xfe5dee046a99a2a811c461f1969c3053),
            uint256(0xfcbe86c7900a88aedcffc83b479aa3a4),
            uint256(0xf987a7253ac413176f2b074cf7815e54),
            uint256(0xf3392b0822b70005940c7a398e4b70f3),
            uint256(0xe7159475a2c29b7443b29c7fa6e889d9),
            uint256(0xd097f3bdfd2022b8845ad8f792aa5825),
            uint256(0xa9f746462d870fdf8a65dc1f90e061e5),
            uint256(0x70d869a156d2a1b890bb3df62baf32f7),
            uint256(0x31be135f97d08fd981231505542fcfa6),
            uint256(0x9aa508b5b7a84e1c677de54f3e99bc9),
            uint256(0x5d6af8dedb81196699c329225ee604),
            uint256(0x2216e584f5fa1ea926041bedfe98),
            uint256(0x48a170391f7dc42444e8fa2)
        ];
        uint256 r=1<<128;
        for(uint256 i;i<20;i++) if(a&(1<<i)!=0) r=(r*f[i])>>128;
        if(tick>0) r=type(uint256).max/r;
        return uint160((r>>32)+(r % (1<<32)==0 ? 0:1));
    }
}
// Rebuilds the aggregate core-liquidity curve. Does NOT claim that all positions
// are locked, and does not count fees or hook-held/off-curve assets as principal.
contract CoreLens {
    struct Snapshot { uint160 sqrtPriceX96; int24 tick; uint128 active; uint24 lpFee; uint24 protocolFee; uint256 wethPrincipal; uint256 surplusPrincipal; uint256 initializedTicks; }
    function state(IManager m,bytes32 id) public view returns(Snapshot memory s) {
        bytes32 root=keccak256(abi.encode(id,uint256(6)));
        uint256 v=uint256(m.extsload(root));
        s.sqrtPriceX96=uint160(v); s.tick=int24(uint24(v>>160));
        s.protocolFee=uint24(v>>184); s.lpFee=uint24(v>>208);
        s.active=uint128(uint256(m.extsload(bytes32(uint256(root)+3))));
        require(s.sqrtPriceX96>0,"pool not initialized");
    }
    function snapshot(IManager m,bytes32 id,int24 spacing) external view returns(Snapshot memory s) {
        s=state(m,id);
        bytes32 root=keccak256(abi.encode(id,uint256(6)));
        bytes32 bitmapRoot=bytes32(uint256(root)+5);
        bytes32 tickRoot=bytes32(uint256(root)+4);
        int256 minWord=(int256(-887272)/int256(spacing))>>8;
        int256 maxWord=(int256(887272)/int256(spacing))>>8;
        int256 running; uint128 atCurrent; int24 prev; bool havePrev;
        for(int256 w=minWord;w<=maxWord;w++) {
            uint256 bitmap=uint256(m.extsload(keccak256(abi.encode(int16(w),bitmapRoot))));
            if(bitmap==0) continue;
            for(uint256 bit;bit<256;bit++) {
                if(bitmap&(uint256(1)<<bit)==0) continue;
                int24 t=int24((w*256+int256(bit))*int256(spacing));
                require(t>=-887272 && t<=887272,"invalid bitmap tick");
                if(havePrev && running>0) {
                    uint128 l=uint128(uint256(running));
                    (uint256 a0,uint256 a1)=amounts(prev,t,l,s.sqrtPriceX96);
                    s.wethPrincipal+=a0; s.surplusPrincipal+=a1;
                    if(prev<=s.tick && s.tick<t) atCurrent=l;
                }
                uint256 packed=uint256(m.extsload(keccak256(abi.encode(t,tickRoot))));
                require(uint128(packed)>0,"initialized tick without liquidityGross");
                running+=int256(int128(uint128(packed>>128)));
                require(running>=0 && uint256(running)<=type(uint128).max,"bad cumulative liquidity");
                prev=t; havePrev=true; s.initializedTicks++;
            }
        }
        require(running==0 && atCurrent==s.active,"core curve did not reconcile");
    }
    function amounts(int24 lo,int24 hi,uint128 l,uint160 p) public pure returns(uint256 a0,uint256 a1) {
        uint256 a=TM.sqrtAt(lo); uint256 b=TM.sqrtAt(hi);
        uint256 s=p<a ? a : (p>b ? b : p);
        a0=FM.mulDiv(uint256(l)<<96,b-s,b)/s;
        a1=FM.mulDiv(l,s-a,1<<96);
    }
}
contract ForkExecutor {
    IManager public immutable manager;
    address public immutable controller;
    PoolKey public key;
    address internal constant PERMIT2=address(uint160(0x00000000000022d473030f116ddee9f6b43ac78ba3));
    address internal constant POSM=address(uint160(0x007c5f5a4bbd8fd63184577525326123b519429bdc));
    constructor(IManager m,PoolKey memory k) { manager=m; key=k; controller=msg.sender; }
    modifier controlled() { require(msg.sender==controller,"controller only"); require(block.chainid==8453,"Base fork expected"); _; }
    function fundWeth() external payable controlled { IWETH(key.currency0).deposit{value:msg.value}(); }
    function change(int24 lo,int24 hi,int256 l,bytes32 salt,bytes memory hd) external controlled {
        manager.unlock(abi.encode(uint8(0),abi.encode(ModifyLiquidityParams(lo,hi,l,salt),hd)));
    }
    function sell(uint256 amount,uint160 limit,bytes memory hd) external controlled {
        require(amount>0 && amount<=uint256(type(int256).max),"bad input");
        manager.unlock(abi.encode(uint8(1),abi.encode(amount,limit,hd)));
    }
    function unlockCallback(bytes calldata payload) external returns(bytes memory) {
        require(msg.sender==address(manager),"manager only");
        (uint8 action,bytes memory d)=abi.decode(payload,(uint8,bytes));
        int256 delta;
        if(action==0) {
            (ModifyLiquidityParams memory p,bytes memory hd)=abi.decode(d,(ModifyLiquidityParams,bytes));
            (delta,)=manager.modifyLiquidity(key,p,hd);
        } else {
            (uint256 amount,uint160 limit,bytes memory hd)=abi.decode(d,(uint256,uint160,bytes));
            // currency0=WETH, currency1=SURPLUS: sell token1, native tick rises.
            delta=manager.swap(key,SwapParams(false,-int256(amount),limit),hd);
        }
        settleDelta(key.currency0,int256(int128(delta>>128)));
        settleDelta(key.currency1,int256(int128(delta)));
        return abi.encode(delta);
    }
    function settleDelta(address token,int256 delta) internal {
        if(delta<0) {
            manager.sync(token);
            safeTransfer(token,address(manager),uint256(-delta));
            require(manager.settle()==uint256(-delta),"unexpected transfer/settlement amount");
        } else if(delta>0) manager.take(token,address(this),uint256(delta));
    }
    function safeTransfer(address token,address to,uint256 amount) internal {
        (bool ok,bytes memory ret)=token.call(abi.encodeCall(IERC20.transfer,(to,amount)));
        require(ok && (ret.length==0 || abi.decode(ret,(bool))),"transfer failed");
    }
    // Tests the deployed PositionManager too, so direct-callback rejection is not
    // mistaken for a universal prohibition on third-party liquidity additions.
    function mintViaPosm(int24 lo,int24 hi,uint128 l,uint128 maxWeth,bytes memory hd) external controlled returns(uint256 id) {
        require(IERC20(key.currency0).approve(PERMIT2,type(uint256).max),"approve failed");
        IPermit2(PERMIT2).approve(key.currency0,POSM,type(uint160).max,type(uint48).max);
        id=IPositionManager(POSM).nextTokenId();
        bytes[] memory p=new bytes[](2);
        p[0]=abi.encode(key,lo,hi,uint256(l),maxWeth,uint128(0),address(this),hd);
        p[1]=abi.encode(key.currency0,key.currency1);
        IPositionManager(POSM).modifyLiquidities(abi.encode(hex"020d",p),block.timestamp+60);
    }
    function burnViaPosm(uint256 id,bytes memory hd) external controlled {
        bytes[] memory p=new bytes[](2);
        p[0]=abi.encode(id,uint128(0),uint128(0),hd);
        p[1]=abi.encode(key.currency0,key.currency1,address(this));
        IPositionManager(POSM).modifyLiquidities(abi.encode(hex"0311",p),block.timestamp+60);
    }
    function onERC721Received(address,address,uint256,bytes calldata) external pure returns(bytes4) { return 0x150b7a02; }
}

/// @dev UniV3 tail executor: sells SURPLUS (token1) for WETH (token0) through a v3 pool's
///      native swap + callback. Scoped to the one tail venue (1% pool) used by the route
///      matrix; the main-pool path stays in ForkExecutor.
interface IV3Pool {
    function swap(address recipient,bool zeroForOne,int256 amountSpecified,uint160 sqrtPriceLimitX96,bytes calldata data)
        external returns(int256,int256);
    function token0() external view returns(address);
    function token1() external view returns(address);
    function fee() external view returns(uint24);
}
/// @dev QuoterV2-shaped view harness: runs a real swap by eth_call from a fresh sender with no
///      balance — callback must fail mid-way, after price impact is computed. We then read the
///      state the failed call moved (slot0) via a REAL swap through SwapRouter02 instead.
///      Deprecated approach: see test_32 which routes the tail via SwapRouter02 eth_call.
contract V3TailExecutor {
    address public immutable controller;
    address public immutable token;
    address public immutable tailPool;
    constructor(address t) { controller=msg.sender; token=t; tailPool=0xbCf23F30a90f6D7c288fACdc932fF8F8B68b0f30; }
    modifier controlled() { require(msg.sender==controller,"controller only"); require(block.chainid==8453,"Base fork expected"); _; }
    function sell(uint256 amountIn,uint160 limit) external controlled {
        // token0=WETH, token1=SUR: selling SUR for WETH ⇒ zeroForOne=false, exact input positive.
        // (The two-delta shape belongs to the CALLBACK, not swap() — fixed 2026-09-24.)
        IV3Pool(tailPool).swap(address(this),false,int256(amountIn),limit,abi.encode(tailPool));
    }
    function uniswapV3SwapCallback(int256 amount0Delta,int256 amount1Delta,bytes calldata data) external {
        address pool=abi.decode(data,(address));
        require(msg.sender==pool && pool==tailPool,"unknown pool");
        require(amount1Delta>0,"wrong direction: expected SUR-in/WETH-out");
        (bool ok,bytes memory ret)=token.call(abi.encodeCall(IERC20.transfer,(pool,uint256(amount1Delta))));
        require(ok && (ret.length==0 || abi.decode(ret,(bool))),"surplus pay failed");
        // amount0Delta < 0: the pool has ALREADY transferred the WETH out to the recipient
        // (v3 settles negative deltas before the callback); nothing more to do for token0.
        require(amount0Delta<=0,"unexpected token0 owed to pool");
    }
}
