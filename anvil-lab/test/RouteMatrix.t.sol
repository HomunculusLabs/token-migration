// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {PoolKey,IERC20,IManager,FM,TM,CoreLens,ForkExecutor,V3TailExecutor} from "../src/ForkSupport.sol";

interface VmRM {
    function envOr(string calldata,uint256) external returns(uint256);
    function envOr(string calldata,int256) external returns(int256);
    function envOr(string calldata,bool) external returns(bool);
    function envBool(string calldata) external returns(bool);
    function envUint(string calldata) external returns(uint256);
    function envAddress(string calldata) external returns(address);
    function envBytes32(string calldata) external returns(bytes32);
    function envOr(string calldata,bytes calldata) external returns(bytes memory);
    function readFile(string calldata) external view returns(string memory);
    function parseJsonAddressArray(string calldata,string calldata) external pure returns(address[] memory);
    function deal(address,uint256) external;
    function prank(address) external;
}

/// @dev ROUTE MATRIX (2026-09-24): lump vs chunked direct sales on the main v4 pool, plus
///      tail routing through the UniV3 1% pool. Same accounting discipline as SurplusForkTest:
///      ETH is synthetic and fully subtracted in net-WETH accounting; SURPLUS comes from real
///      fork donors; hook WETH delta tracked separately. forge isolates each test on its own
///      fork snapshot, so runs at different CHUNKS do not contaminate each other.
contract RouteMatrixTest {
    VmRM constant vm=VmRM(address(uint160(uint256(keccak256("hevm cheat code")))));
    address constant WETH=address(uint160(0x004200000000000000000000000000000000000006));
    address constant TOKEN=address(uint160(0x00c52aedec3374422d7510e294cfaa90799595cba3));
    IManager constant MANAGER=IManager(address(uint160(0x00498581ff718922c3f8e6a244956af099b2652b2b)));
    bytes32 constant ID=0xfc25fdd217e288d03a877f0b7d49e0bbe52b2288c88de929125062569fc7eb2a;
    CoreLens lens; ForkExecutor actor; V3TailExecutor tail; PoolKey key;
    event log(string);
    event log_named_uint(string key,uint256 val);
    event log_named_int(string key,int256 val);

    function setUp() public {
        require(vm.envBool("SURPLUS_FORK_ACK"),"Run through run.sh on local Anvil");
        require(block.chainid==8453,"Keep Base chain ID on the fork");
        require(block.number==vm.envUint("FORK_BLOCK"),"Wrong fork block");
        uint256 spacing=vm.envUint("POOL_TICK_SPACING");
        uint256 fee=vm.envUint("POOL_FEE");
        require(spacing>0 && spacing<=32767 && fee<=type(uint24).max,"bad discovered key");
        key=PoolKey(WETH,TOKEN,uint24(fee),int24(int256(spacing)),vm.envAddress("POOL_HOOK"));
        require(keccak256(abi.encode(key))==ID,"PoolKey hash mismatch");
        require(key.hooks.codehash==vm.envBytes32("POOL_HOOK_CODEHASH"),"Hook runtime changed / wrong fork");
        lens=new CoreLens();
        actor=new ForkExecutor(MANAGER,key);
        tail=new V3TailExecutor(TOKEN);
        // Only ETH is synthetic; it is wrapped normally and fully subtracted in net accounting.
        vm.deal(address(this),2 ether);
        actor.fundWeth{value:2 ether}();
    }

    /// @dev Fund `amount` SURPLUS from the donor list — identical rules to SurplusForkTest.
    function fundSurplus() internal returns(uint256 amount) {
        uint8 decimals=IERC20(TOKEN).decimals();
        require(decimals<=36,"unexpected decimals");
        amount=vm.envOr("SELL_AMOUNT_RAW",vm.envOr("SELL_TOKENS",uint256(1000000))*(10**decimals));
        require(amount>0 && amount<=IERC20(TOKEN).totalSupply(),"invalid sale inventory");
        address[] memory donors=vm.parseJsonAddressArray(vm.readFile("donors.json"),".addresses");
        require(donors.length>0,"Populate donors.json with EOA holders for local transfer simulation");
        uint256 totalBefore=IERC20(TOKEN).totalSupply();
        uint256 missing=amount;
        for(uint256 i;i<donors.length && missing>0;i++) {
            address d=donors[i];
            require(d!=address(0) && d!=address(MANAGER) && d!=key.hooks && d!=address(actor),"forbidden donor");
            require(d.code.length==0,"EOA donors only; review contract custody separately");
            uint256 bal=IERC20(TOKEN).balanceOf(d);
            uint256 take=bal<missing ? bal:missing;
            if(take==0) continue;
            uint256 had=IERC20(TOKEN).balanceOf(address(actor));
            vm.prank(d);
            (bool ok,bytes memory data)=TOKEN.call(abi.encodeCall(IERC20.transfer,(address(actor),take)));
            require(ok && (data.length==0 || abi.decode(data,(bool))),"donor transfer failed");
            require(IERC20(TOKEN).balanceOf(d)==bal-take && IERC20(TOKEN).balanceOf(address(actor))==had+take,"nonstandard transfer; review token");
            missing-=take;
        }
        require(missing==0,"Donors do not cover requested tokens at pinned block");
        require(IERC20(TOKEN).totalSupply()==totalBefore,"Unexpected supply change");
    }

    /// @dev Route surplus from actor to the tail executor for the v3 leg.
    function stageTail(uint256 amount) internal {
        vm.prank(address(actor)); // tokens live in the actor after fundSurplus/sale remainder
        (bool ok,bytes memory ret)=TOKEN.call(abi.encodeCall(IERC20.transfer,(address(tail),amount)));
        require(ok && (ret.length==0 || abi.decode(ret,(bool))),"stage tail failed");
    }

    function priceLimit() internal returns(uint160) {
        uint256 lim=vm.envOr("SQRT_PRICE_LIMIT_X96",uint256(TM.MAX_SQRT)-1);
        CoreLens.Snapshot memory s=lens.state(MANAGER,ID);
        require(lim>s.sqrtPriceX96 && lim<TM.MAX_SQRT,"wrong sell price limit");
        return uint160(lim);
    }

    /// @dev Lump vs chunked direct sale on the main v4 pool. CHUNKS=1 reproduces the lump
    ///      baseline; higher CHUNKS measure whether splitting changes realized WETH (it should
    ///      NOT matter for a pure AMM, but the fee here is DYNAMIC — hook-set per swap — so
    ///      chunking could change the fee actually charged; this measures exactly that).
    function test_30_lump_vs_chunks() public {
        uint256 initial=fundSurplus();
        uint256 chunks=vm.envOr("CHUNKS",uint256(1));
        require(chunks>=1 && chunks<=64,"CHUNKS in [1,64]");
        uint256 per=initial/chunks;
        require(per>0,"CHUNKS too large for amount");

        CoreLens.Snapshot memory before=lens.snapshot(MANAGER,ID,key.tickSpacing);
        uint256 wethBefore=IERC20(WETH).balanceOf(address(actor));
        uint256 hookBefore=IERC20(WETH).balanceOf(key.hooks);
        bytes memory sd=vm.envOr("SWAP_HOOK_DATA",bytes(""));

        for(uint256 c=0;c<chunks;c++) {
            uint256 amt=(c==chunks-1)?(initial-per*(chunks-1)):per;
            actor.sell(amt,priceLimit(),sd);
        }

        uint256 wethAfter=IERC20(WETH).balanceOf(address(actor));
        CoreLens.Snapshot memory afterS=lens.snapshot(MANAGER,ID,key.tickSpacing);
        emit log_named_uint("chunks",chunks);
        emit log_named_uint("initial_surplus_inventory_raw",initial);
        emit log_named_int("net_weth_recovered_wei",int256(wethAfter)-int256(wethBefore));
        emit log_named_int("hook_weth_wallet_delta_wei",int256(IERC20(WETH).balanceOf(key.hooks))-int256(hookBefore));
        emit log_named_int("end_tick",afterS.tick);
        emit log_named_uint("end_active_liquidity",afterS.active);
        emit log_named_uint("surplus_left_raw",IERC20(TOKEN).balanceOf(address(actor)));
        emit log_named_int("before_tick",before.tick);
        emit log("WETH net already subtracts supplied seed. Gas/L1 fees/MEV are NOT deducted.");
    }

    /// @dev Split route: main pool first (MAIN_SHARE of inventory), remainder through the v3
    ///      1% tail pool. MAIN_SHARE is per-10_000 (10000 = all-main baseline ≡ lump sale).
    function test_31_main_plus_v3_tail() public {
        uint256 initial=fundSurplus();
        uint256 share=vm.envOr("MAIN_SHARE_BPS",uint256(10_000));
        require(share<=10_000,"MAIN_SHARE_BPS in [0,10000]");
        uint256 mainAmount=initial*share/10_000;
        uint256 tailAmount=initial-mainAmount;

        uint256 wethBefore=IERC20(WETH).balanceOf(address(actor));
        uint256 hookBefore=IERC20(WETH).balanceOf(key.hooks);
        bytes memory sd=vm.envOr("SWAP_HOOK_DATA",bytes(""));

        if(mainAmount>0) actor.sell(mainAmount,priceLimit(),sd);
        uint256 wethAfterMain=IERC20(WETH).balanceOf(address(actor));

        if(tailAmount>0) {
            stageTail(tailAmount);
            tail.sell(tailAmount,1460168201850918948858605174782982628738293285); // v3 TickMath.MAX_SQRT_RATIO-1: selling token1 pushes price UP
        }
        uint256 wethAfterTail=IERC20(WETH).balanceOf(address(tail));

        emit log_named_uint("main_amount_raw",mainAmount);
        emit log_named_uint("tail_amount_raw",tailAmount);
        emit log_named_int("main_leg_weth_wei",int256(wethAfterMain)-int256(wethBefore));
        emit log_named_int("tail_leg_weth_wei",int256(wethAfterTail));
        emit log_named_int("total_weth_wei",int256(wethAfterMain)-int256(wethBefore)+int256(wethAfterTail));
        emit log_named_int("hook_weth_wallet_delta_wei",int256(IERC20(WETH).balanceOf(key.hooks))-int256(hookBefore));
        emit log_named_uint("surplus_left_actor_raw",IERC20(TOKEN).balanceOf(address(actor)));
        emit log_named_uint("surplus_left_tail_raw",IERC20(TOKEN).balanceOf(address(tail)));
        emit log("Tail leg routed through Uniswap v3 1% pool 0xbCf2...0f30 via native callback.");
    }
}
