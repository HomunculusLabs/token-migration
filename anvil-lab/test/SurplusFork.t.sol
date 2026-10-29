// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {PoolKey,IERC20,IManager,FM,TM,CoreLens,ForkExecutor} from "../src/ForkSupport.sol";
interface Vm {
    function envAddress(string calldata) external returns(address);
    function envUint(string calldata) external returns(uint256);
    function envBytes32(string calldata) external returns(bytes32);
    function envBool(string calldata) external returns(bool);
    function envOr(string calldata,uint256) external returns(uint256);
    function envOr(string calldata,int256) external returns(int256);
    function envOr(string calldata,bool) external returns(bool);
    function envOr(string calldata,bytes calldata) external returns(bytes memory);
    function readFile(string calldata) external view returns(string memory);
    function parseJsonAddressArray(string calldata,string calldata) external pure returns(address[] memory);
    function deal(address,uint256) external;
    function prank(address) external;
}
contract SurplusForkTest {
    Vm constant vm=Vm(address(uint160(uint256(keccak256("hevm cheat code")))));
    address constant WETH=address(uint160(0x004200000000000000000000000000000000000006));
    address constant TOKEN=address(uint160(0x00c52aedec3374422d7510e294cfaa90799595cba3));
    IManager constant MANAGER=IManager(address(uint160(0x00498581ff718922c3f8e6a244956af099b2652b2b)));
    bytes32 constant ID=0xfc25fdd217e288d03a877f0b7d49e0bbe52b2288c88de929125062569fc7eb2a;
    bytes32 constant SALT=keccak256("SURPLUS_LOCAL_LAB_POSITION");
    CoreLens lens; ForkExecutor actor; PoolKey key;
    uint256 wethBudget; uint256 wethSeed; uint160 limit;
    int24 rangeLower; int24 rangeUpper; uint128 positionLiquidity;
    bytes addData; bytes swapData; bytes removeData;
    event log(string);
    event log_named_address(string key,address val);
    event log_named_uint(string key,uint256 val);
    event log_named_int(string key,int256 val);
    event log_named_bytes32(string key,bytes32 val);

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
        lens=new CoreLens(); actor=new ForkExecutor(MANAGER,key);
        wethBudget=vm.envOr("LP_WETH_BUDGET_WEI",uint256(1e15));
        require(wethBudget>0 && wethBudget<type(uint128).max-1 ether,"bad WETH budget");
        wethSeed=wethBudget+1 ether;
        // Only ETH is synthetic; it is wrapped normally and fully subtracted in
        // net-WETH accounting. SURPLUS is transferred from real fork holders.
        vm.deal(address(this),wethSeed);
        actor.fundWeth{value:wethSeed}();
        CoreLens.Snapshot memory s=lens.state(MANAGER,ID);
        int256 step=int256(key.tickSpacing);
        int256 next=((int256(s.tick)/step)*step);
        if(next<=s.tick) next+=step;
        int256 gap=int256(vm.envOr("RANGE_GAP_TICKS",uint256(23000)));
        int256 width=int256(vm.envOr("RANGE_WIDTH_TICKS",uint256(7000)));
        int256 lower=next+((gap+step-1)/step)*step;
        lower=vm.envOr("RANGE_TICK_LOWER",lower);
        int256 upper=lower+((width+step-1)/step)*step;
        upper=vm.envOr("RANGE_TICK_UPPER",upper);
        require(lower>s.tick && upper>lower && lower>=-887272 && upper<=887272,"range not below SURPLUS price / out of bounds");
        require(lower%step==0 && upper%step==0,"range ticks must match spacing");
        rangeLower=int24(lower); rangeUpper=int24(upper);
        uint256 a=TM.sqrtAt(rangeLower); uint256 b=TM.sqrtAt(rangeUpper);
        uint256 l=FM.mulDiv(wethBudget,FM.mulDiv(a,b,1<<96),b-a);
        require(l>0 && l<=type(uint128).max,"liquidity sizing invalid");
        positionLiquidity=uint128(l);
        uint256 lim=vm.envOr("SQRT_PRICE_LIMIT_X96",uint256(TM.MAX_SQRT)-1);
        require(lim>s.sqrtPriceX96 && lim<TM.MAX_SQRT,"wrong sell price limit");
        limit=uint160(lim);
        addData=vm.envOr("ADD_HOOK_DATA",bytes(""));
        swapData=vm.envOr("SWAP_HOOK_DATA",bytes(""));
        removeData=vm.envOr("REMOVE_HOOK_DATA",bytes(""));
    }
    function test_00_metadata_and_core() public {
        emit log("DIAGNOSTIC: current full pool, not a verified locked-only subset");
        emit log_named_uint("base_block",block.number);
        emit log_named_address("hook",key.hooks);
        emit log_named_bytes32("hook_runtime_hash",key.hooks.codehash);
        emit log_named_uint("pool_key_fee",key.fee);
        emit log_named_uint("tick_spacing",uint256(uint24(key.tickSpacing)));
        emit log_named_int("lower_human_price_range_native_tick_lower",rangeLower);
        emit log_named_int("lower_human_price_range_native_tick_upper",rangeUpper);
        printState("before",lens.snapshot(MANAGER,ID,key.tickSpacing));
    }
    function test_01_direct_add_then_remove() public {
        uint256 beforeWeth=IERC20(WETH).balanceOf(address(actor));
        uint256 beforeToken=IERC20(TOKEN).balanceOf(address(actor));
        actor.change(rangeLower,rangeUpper,int256(uint256(positionLiquidity)),SALT,addData);
        emit log_named_int("add_weth_wallet_change_wei",int256(IERC20(WETH).balanceOf(address(actor)))-int256(beforeWeth));
        emit log_named_int("add_surplus_wallet_change_raw",int256(IERC20(TOKEN).balanceOf(address(actor)))-int256(beforeToken));
        actor.change(rangeLower,rangeUpper,-int256(uint256(positionLiquidity)),SALT,removeData);
        emit log_named_int("roundtrip_net_weth_wei",int256(IERC20(WETH).balanceOf(address(actor)))-int256(beforeWeth));
        emit log("PASS only means this executor and hookData could add AND remove in this state");
    }
    function test_02_position_manager_add_then_remove() public {
        uint256 beforeWeth=IERC20(WETH).balanceOf(address(actor));
        uint256 id=actor.mintViaPosm(rangeLower,rangeUpper,positionLiquidity,uint128(wethSeed),addData);
        emit log_named_uint("new_local_position_id",id);
        actor.burnViaPosm(id,removeData);
        emit log_named_int("posm_roundtrip_net_weth_wei",int256(IERC20(WETH).balanceOf(address(actor)))-int256(beforeWeth));
    }
    function test_20_direct_sale() public { runScenario(0); }
    function test_21_add_sell_remove() public { runScenario(1); }
    function test_22_add_sell_remove_resell() public { runScenario(2); }

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
        emit log_named_uint("surplus_decimals",decimals);
        emit log_named_uint("initial_surplus_inventory_raw",amount);
    }
    function runScenario(uint256 mode) internal {
        uint256 initial=fundSurplus();
        CoreLens.Snapshot memory beforeState=lens.snapshot(MANAGER,ID,key.tickSpacing);
        uint256 initialWeth=IERC20(WETH).balanceOf(address(actor));
        uint256 hookWeth=IERC20(WETH).balanceOf(key.hooks);
        uint256 startGas=gasleft();
        uint256 lpId;
        bool viaPosm=vm.envOr("USE_POSITION_MANAGER",false);
        if(mode>0) {
            if(viaPosm) lpId=actor.mintViaPosm(rangeLower,rangeUpper,positionLiquidity,uint128(wethSeed),addData);
            else actor.change(rangeLower,rangeUpper,int256(uint256(positionLiquidity)),SALT,addData);
        }
        uint256 afterAddWeth=IERC20(WETH).balanceOf(address(actor));
        actor.sell(initial,limit,swapData);
        uint256 afterFirstSaleWeth=IERC20(WETH).balanceOf(address(actor));
        uint256 afterFirstSaleToken=IERC20(TOKEN).balanceOf(address(actor));
        if(mode>0) {
            if(viaPosm) actor.burnViaPosm(lpId,removeData);
            else actor.change(rangeLower,rangeUpper,-int256(uint256(positionLiquidity)),SALT,removeData);
        }
        uint256 afterRemoveToken=IERC20(TOKEN).balanceOf(address(actor));
        uint256 resellAmount;
        if(mode==2 && afterRemoveToken>0 && lens.state(MANAGER,ID).sqrtPriceX96<limit) {
            resellAmount=afterRemoveToken;
            actor.sell(resellAmount,limit,swapData);
        }
        uint256 executionGas=startGas-gasleft();
        uint256 endWeth=IERC20(WETH).balanceOf(address(actor));
        uint256 endToken=IERC20(TOKEN).balanceOf(address(actor));
        CoreLens.Snapshot memory afterState=lens.snapshot(MANAGER,ID,key.tickSpacing);
        emit log_named_uint("scenario_mode",mode);
        emit log_named_uint("initial_weth_seed_wei",initialWeth);
        emit log_named_int("lp_add_weth_cost_wei",int256(initialWeth)-int256(afterAddWeth));
        emit log_named_int("first_swap_weth_received_wei",int256(afterFirstSaleWeth)-int256(afterAddWeth));
        emit log_named_uint("surplus_left_after_first_swap_raw",afterFirstSaleToken);
        emit log_named_int("surplus_returned_by_lp_removal_raw",int256(afterRemoveToken)-int256(afterFirstSaleToken));
        emit log_named_uint("resell_requested_raw",resellAmount);
        emit log_named_uint("surplus_left_final_raw",endToken);
        emit log_named_int("net_surplus_spent_raw",int256(initial)-int256(endToken));
        emit log_named_int("net_weth_recovered_wei",int256(endWeth)-int256(initialWeth));
        emit log_named_int("hook_weth_wallet_delta_wei",int256(IERC20(WETH).balanceOf(key.hooks))-int256(hookWeth));
        emit log_named_uint("execution_gas_diagnostic_excludes_initial_funding_and_reserve_scan",executionGas);
        printState("before",beforeState); printState("after",afterState);
        emit log("WETH net already subtracts supplied seed. Gas/L1 fees/MEV are NOT deducted.");
        emit log("Core reserve estimates exclude accrued fees and hook-held/off-curve assets.");
        emit log("Existing third-party LP was not removed. This is NOT a locked-only test.");
    }
    function printState(string memory prefix,CoreLens.Snapshot memory s) internal {
        emit log_named_uint(string.concat(prefix,"_sqrtPriceX96"),s.sqrtPriceX96);
        emit log_named_int(string.concat(prefix,"_native_tick"),s.tick);
        emit log_named_uint(string.concat(prefix,"_active_liquidity"),s.active);
        emit log_named_uint(string.concat(prefix,"_lp_fee_pips"),s.lpFee);
        emit log_named_uint(string.concat(prefix,"_protocol_fee_packed"),s.protocolFee);
        emit log_named_uint(string.concat(prefix,"_core_weth_principal_wei"),s.wethPrincipal);
        emit log_named_uint(string.concat(prefix,"_core_surplus_principal_raw"),s.surplusPrincipal);
        emit log_named_uint(string.concat(prefix,"_initialized_ticks"),s.initializedTicks);
    }
}
