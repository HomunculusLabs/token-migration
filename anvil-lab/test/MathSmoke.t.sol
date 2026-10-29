// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {FM,TM,CoreLens} from "../src/ForkSupport.sol";
contract MathSmokeTest {
    function test_tick_vectors() public pure {
        require(TM.sqrtAt(0)==79228162514264337593543950336,"tick0");
        require(TM.sqrtAt(-887272)==4295128739,"min tick");
        require(TM.sqrtAt(887272)==1461446703485210103287273052203988822378723970342,"max tick");
        require(TM.sqrtAt(1)==79232123823359799118286999568,"tick1");
    }
    function test_full_precision_muldiv() public pure {
        require(FM.mulDiv(uint256(1)<<200,uint256(1)<<100,uint256(1)<<100)==uint256(1)<<200,"512bit muldiv");
        require(FM.mulDiv(17,19,7)==46,"floor");
    }
    function test_range_single_sided_endpoints() public {
        CoreLens l=new CoreLens();
        (uint256 a,uint256 b)=l.amounts(100,200,1e18,TM.sqrtAt(0));
        require(a>0 && b==0,"below native range must be currency0-only");
        (a,b)=l.amounts(100,200,1e18,TM.sqrtAt(300));
        require(a==0 && b>0,"above native range must be currency1-only");
    }
}
