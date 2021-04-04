pragma solidity 0.6.12;

import "@pancakeswap/pancake-swap-lib/contracts/access/Ownable.sol";
import "@pancakeswap/pancake-swap-lib/contracts/math/SafeMath.sol";
import "@pancakeswap/pancake-swap-lib/contracts/token/BEP20/IBEP20.sol";
import "@pancakeswap/pancake-swap-lib/contracts/token/BEP20/SafeBEP20.sol";
import "./UraniumMoneyPot.sol";
import "./interfaces/IUraniumRouter02.sol";
import "./interfaces/IUraniumPair.sol";
import "./RadsToken.sol";

contract FeeManager is Ownable{
    using SafeMath for uint16;
    using SafeMath for uint256;
    using SafeBEP20 for IBEP20;

    uint16 public moneyPotShare;
    uint16 public teamShare;

    UraniumMoneyPot public moneyPot;
    IUraniumRouter02 public router;
    RadsToken public rads;

    address public teamAddr; // Used for dev/marketing and others funds for project

    mapping (address => bool) _feeTargetTokens;


    constructor (RadsToken _rads, address _teamAddr,
                uint16 _moneyPotShare, uint16 _teamShare) public{
        rads = _rads;
        teamAddr = _teamAddr;
        moneyPotShare = _moneyPotShare;
        teamShare = _teamShare;
    }


    function isFeeTargetToken(address _token) external view returns  (bool){
        return moneyPot.tokenInitialized(_token);
    }

    function removeLiquidityToToken(address _token) external{
        IUraniumPair _pair = IUraniumPair(_token);
        uint256 _amount = _pair.balanceOf(address(this));
        address token0 = _pair.token0();
        address token1 = _pair.token1();

        _pair.approve(address(router), _amount);
        router.removeLiquidity(token0, token1, _amount, 0, 0, address(this), block.timestamp.add(100));
    }

    function swapBalanceToToken(address _token0, address _token1) external onlyOwner {
        require(_token0 != address(rads), "");
        uint256 _amount = IBEP20(_token0).balanceOf(address(this));
        IBEP20(_token0).approve(address(router), _amount);
        address[] memory path = new address[](2);
        path[0] = _token0;
        path[1] = _token1;
        router.swapExactTokensForTokens(_amount, 0, path, address(this), block.timestamp.add(100));
    }

    function updateShares(uint16 _moneyPotShare, uint16 _teamShare) external onlyOwner{
        require(_moneyPotShare.add(_teamShare) == 10000, "Invalid percent");
        require(_moneyPotShare <= moneyPotShare, "Cannot decrease MoneyPotShare");
        moneyPotShare = _moneyPotShare;
        teamShare = _teamShare;
    }

    function setTeamAddr(address _newTeamAddr) external onlyOwner{
        teamAddr = _newTeamAddr;
    }

    function setupRouter(address _router) external onlyOwner{
        router = IUraniumRouter02(_router);
    }

    function setupMoneyPot(UraniumMoneyPot _moneyPot) external onlyOwner{
        require(address(moneyPot) == address(0), "moneyPot already setup");
        moneyPot = _moneyPot;
    }

    function distributeFee() external {
        uint256 length = moneyPot.getRegisteredTokenLength();
        for (uint256 index = 0; index < length; ++index) {
            IBEP20 _curToken = IBEP20(moneyPot.registeredToken(index));
            uint256 _amount = _curToken.balanceOf(address(this));
            uint256 _moneyPotAmount = _amount.mul(moneyPotShare).div(10000);
            _curToken.approve(address(moneyPot), _moneyPotAmount);
            moneyPot.depositRewards(address(_curToken), _moneyPotAmount);
            _curToken.safeTransfer(teamAddr, _amount.sub(_moneyPotAmount));
        }
        if (rads.balanceOf(address(this)) > 0){
            rads.transfer(address(0x000000000000000000000000000000000000dEaD), rads.balanceOf(address(this)));
        }
    }

}