pragma solidity 0.6.12;

import "@pancakeswap/pancake-swap-lib/contracts/access/Ownable.sol";
import "@pancakeswap/pancake-swap-lib/contracts/math/SafeMath.sol";
import "@pancakeswap/pancake-swap-lib/contracts/token/BEP20/IBEP20.sol";
import "@pancakeswap/pancake-swap-lib/contracts/token/BEP20/SafeBEP20.sol";
import "./interfaces/IMoneyPot.sol";
import "./interfaces/IUraniumRouter02.sol";
import "./interfaces/IUraniumPair.sol";

/*
The FeeManager is a kind of contract-wallet that allow the owner to unbind (LP) and swap tokens
to BNB/BUSD before sending them to the Money Pot
*/
contract FeeManager is Ownable{
    using SafeMath for uint256;
    using SafeBEP20 for IBEP20;

    uint256 public moneyPotShare;
    uint256 public teamShare;

    IMoneyPot public moneyPot;
    IUraniumRouter02 public router;
    IBEP20 public rads;

    address public teamAddr; // Used for dev/marketing and others funds for project

    address public constant BURN_ADDRESS = 0x000000000000000000000000000000000000dEaD;

    constructor (IBEP20 _rads, address _teamAddr,
                uint256 _moneyPotShare) public{
        rads = _rads;
        teamAddr = _teamAddr;
        moneyPotShare = _moneyPotShare;
        teamShare = 10000 - moneyPotShare;
    }

    function removeLiquidityToToken(address _token) external onlyOwner{
        IUraniumPair _pair = IUraniumPair(_token);
        uint256 _amount = _pair.balanceOf(address(this));
        address token0 = _pair.token0();
        address token1 = _pair.token1();

        _pair.approve(address(router), _amount);
        router.removeLiquidity(token0, token1, _amount, 0, 0, address(this), block.timestamp.add(100));
    }

    function swapBalanceToToken(address _token0, address _token1) external onlyOwner {
        require(_token0 != address(rads), "rads can only be burn");
        uint256 _amount = IBEP20(_token0).balanceOf(address(this));
        IBEP20(_token0).approve(address(router), _amount);
        address[] memory path = new address[](2);
        path[0] = _token0;
        path[1] = _token1;
        router.swapExactTokensForTokens(_amount, 0, path, address(this), block.timestamp.add(100));
    }

    function swapToToken(address _token0, address _token1, uint256 _token0Amount) external onlyOwner {
        require(_token0 != address(rads), "rads can only be burn");
        IBEP20(_token0).approve(address(router), _token0Amount);
        address[] memory path = new address[](2);
        path[0] = _token0;
        path[1] = _token1;
        router.swapExactTokensForTokens(_token0Amount, 0, path, address(this), block.timestamp.add(100));
    }

    function updateShares(uint256 _moneyPotShare) external onlyOwner{
        require(_moneyPotShare <= 10000, "Invalid percent");
        require(_moneyPotShare >= 7500, "Moneypot share must be at least 75%");
        moneyPotShare = _moneyPotShare;
        teamShare = 10000 - moneyPotShare;
    }

    function setTeamAddr(address _newTeamAddr) external onlyOwner{
        teamAddr = _newTeamAddr;
    }

    function setupRouter(address _router) external onlyOwner{
        router = IUraniumRouter02(_router);
    }

    function setupMoneyPot(IMoneyPot _moneyPot) external onlyOwner{
        moneyPot = _moneyPot;
    }

    /* distribute fee to the moneypot and dev wallet  */
    function distributeFee() external onlyOwner {
        uint256 length = moneyPot.getRegisteredTokenLength();
        for (uint256 index = 0; index < length; ++index) {
            IBEP20 _curToken = IBEP20(moneyPot.getRegisteredToken(index));
            uint256 _amount = _curToken.balanceOf(address(this));
            uint256 _moneyPotAmount = _amount.mul(moneyPotShare).div(10000);
            _curToken.approve(address(moneyPot), _moneyPotAmount);
            moneyPot.depositRewards(address(_curToken), _moneyPotAmount);
            _curToken.safeTransfer(teamAddr, _amount.sub(_moneyPotAmount));
        }
        if (rads.balanceOf(address(this)) > 0){
            rads.transfer(BURN_ADDRESS, rads.balanceOf(address(this)));
        }
    }
}