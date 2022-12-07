// SPDX-License-Identifier: MIT

pragma solidity ^0.8.10;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "./interface/DividendPayingTokenInterface.sol";
import "./interface/DividendPayingTokenOptionalInterface.sol";
import "./interface/IUniswapV2Router02.sol";
import "./library/SafeMathInt.sol";
import "./library/SafeMathUint.sol";

/// @title Dividend-Paying Token
/// @author Roger Wu (https://github.com/roger-wu)
/// @dev A mintable ERC20 token that allows anyone to pay and distribute ether
///  to token holders as dividends and allows token holders to withdraw their dividends.
///  Reference: the source code of PoWH3D: https://etherscan.io/address/0xB3775fB83F7D12A36E0475aBdD1FCA35c091efBe#code
contract DividendPayingToken is
    ERC20,
    DividendPayingTokenInterface,
    DividendPayingTokenOptionalInterface,
    Ownable
{
    using SafeMath for uint256;
    using SafeMathUint for uint256;
    using SafeMathInt for int256;

    // With `magnitude`, we can properly distribute dividends even if the amount of received ether is small.
    // For more discussion about choosing the value of `magnitude`,
    //  see https://github.com/ethereum/EIPs/issues/1726#issuecomment-472352728
    uint256 internal constant magnitude = 2**128;

    uint256 internal magnifiedDividendPerShare;

    // About dividendCorrection:
    // If the token balance of a `_user` is never changed, the dividend of `_user` can be computed with:
    //   `dividendOf(_user) = dividendPerShare * balanceOf(_user)`.
    // When `balanceOf(_user)` is changed (via minting/burning/transferring tokens),
    //   `dividendOf(_user)` should not be changed,
    //   but the computed value of `dividendPerShare * balanceOf(_user)` is changed.
    // To keep the `dividendOf(_user)` unchanged, we add a correction term:
    //   `dividendOf(_user) = dividendPerShare * balanceOf(_user) + dividendCorrectionOf(_user)`,
    //   where `dividendCorrectionOf(_user)` is updated whenever `balanceOf(_user)` is changed:
    //   `dividendCorrectionOf(_user) = dividendPerShare * (old balanceOf(_user)) - (new balanceOf(_user))`.
    // So now `dividendOf(_user)` returns the same value before and after `balanceOf(_user)` is changed.
    mapping(address => int256) internal magnifiedDividendCorrections;
    mapping(address => uint256) internal withdrawnDividends;
    mapping(address => uint256) internal rawBNBWithdrawnDividends;
    mapping(address => address) public userCurrentRewardToken;
    mapping(address => bool) public userHasCustomRewardToken;
    mapping(address => address) public userCurrentRewardAMM;
    mapping(address => bool) public userHasCustomRewardAMM;
    mapping(address => uint256) public rewardTokenSelectionCount; // Keep track of how many people have each reward token selected
    mapping(address => bool) public ammIsWhiteListed; // Only allow whitelisted AMMs
    mapping(address => bool) public blackListRewardTokens;

    // @note Router address for PancakeSwap v2 (LIVE) @note enabled
    IUniswapV2Router02 public uniswapV2Router =
        IUniswapV2Router02(0x10ED43C718714eb63d5aA57B78B54704E256024E);

    // @note Router address for PancakeSwap (TESTNET) @note disabled
    // IUniswapV2Router02 public uniswapV2Router = IUniswapV2Router02(0xD99D1c33F9fC3444f8101754aBC46c52416550D1);

    function updateDividendUniswapV2Router(address newAddress)
        external
        onlyOwner
    {
        require(
            newAddress != address(uniswapV2Router),
            "ALTSWITCH: The router already has that address"
        );
        uniswapV2Router = IUniswapV2Router02(newAddress);
    }

    uint256 public totalDividendsDistributed; // dividends distributed per reward token

    // @note Whitelisted AMMs
    constructor(
        string memory _name,
        string memory _symbol
    ) ERC20(_name, _symbol) {
        ammIsWhiteListed[
            address(0x10ED43C718714eb63d5aA57B78B54704E256024E)
        ] = true; // PCS V2 router @note enabled
        // ammIsWhiteListed[address(0x05fF2B0DB69458A0750badebc4f9e13aDd608C7F)] = true; // PCS V1 router @note disabled
        // ammIsWhiteListed[address(0xcF0feBd3f17CEf5b47b0cD257aCf6025c5BFf3b7)] = true; // ApeSwap router @note disabled
        // ammIsWhiteListed[address(0xD99D1c33F9fC3444f8101754aBC46c52416550D1)] = true; // PCS Testnet router @note disabled
    }

    /// @dev Distributes dividends whenever ether is paid to this contract.
    receive() external payable {
        distributeDividends();
    }

    // Customized function to send tokens to dividend recipients
    function swapETHForTokens(address recipient, uint256 ethAmount)
        private
        returns (uint256)
    {
        bool swapSuccess;
        IERC20 token = IERC20(userCurrentRewardToken[recipient]);
        IUniswapV2Router02 swapRouter = uniswapV2Router;

        if (
            userHasCustomRewardAMM[recipient] &&
            ammIsWhiteListed[userCurrentRewardAMM[recipient]]
        ) {
            swapRouter = IUniswapV2Router02(userCurrentRewardAMM[recipient]);
        }

        // generate the pancake pair path of token -> weth
        address[] memory path = new address[](2);
        path[0] = swapRouter.WETH();
        path[1] = address(token);

        // make the swap
        try
            swapRouter.swapExactETHForTokensSupportingFeeOnTransferTokens{
                value: ethAmount
            }( //try to swap for tokens, if it fails (bad contract, or whatever other reason, send BNB)
                1, // accept any amount of Tokens above 1 wei (so it will fail if nothing returns)
                path,
                address(recipient),
                block.timestamp + 360
            )
        {
            swapSuccess = true;
        } catch {
            swapSuccess = false;
        }

        // if the swap failed, send them their BNB instead
        if (!swapSuccess) {
            rawBNBWithdrawnDividends[recipient] = rawBNBWithdrawnDividends[
                recipient
            ].add(ethAmount);
            (bool success, ) = recipient.call{value: ethAmount, gas: 3000}("");

            if (!success) {
                withdrawnDividends[recipient] = withdrawnDividends[recipient]
                    .sub(ethAmount);
                rawBNBWithdrawnDividends[recipient] = rawBNBWithdrawnDividends[
                    recipient
                ].sub(ethAmount);
                return 0;
            }
        }
        return ethAmount;
    }

    function setBlacklistToken(address tokenAddress, bool isBlacklisted)
        external
        onlyOwner
    {
        blackListRewardTokens[tokenAddress] = isBlacklisted;
    }

    function isBlacklistedToken(address tokenAddress)
        public
        view
        returns (bool)
    {
        return blackListRewardTokens[tokenAddress];
    }

    function getRawBNBDividends(address holder)
        external
        view
        returns (uint256)
    {
        return rawBNBWithdrawnDividends[holder];
    }

    function setWhiteListAMM(address ammAddress, bool whitelisted)
        external
        onlyOwner
    {
        ammIsWhiteListed[ammAddress] = whitelisted;
    }

    // call this to set a custom reward token (call from token contract only)
    function setRewardToken(
        address holder,
        address rewardTokenAddress,
        address ammContractAddress
    ) external {
        if (userHasCustomRewardToken[holder] == true) {
            if (rewardTokenSelectionCount[userCurrentRewardToken[holder]] > 0) {
                rewardTokenSelectionCount[userCurrentRewardToken[holder]] -= 1; // remove count from old token
            }
        }

        userHasCustomRewardToken[holder] = true;
        userCurrentRewardToken[holder] = rewardTokenAddress;
        // only set custom AMM if the AMM is whitelisted.
        if (
            ammContractAddress != address(uniswapV2Router) &&
            ammIsWhiteListed[ammContractAddress]
        ) {
            userHasCustomRewardAMM[holder] = true;
            userCurrentRewardAMM[holder] = ammContractAddress;
        } else {
            userHasCustomRewardAMM[holder] = false;
            userCurrentRewardAMM[holder] = address(uniswapV2Router);
        }
        rewardTokenSelectionCount[rewardTokenAddress] += 1; // add count to new token
    }

    // call this to go back to receiving BNB after setting another token. (call from token contract only)
    function unsetRewardToken(address holder) external {
        userHasCustomRewardToken[holder] = false;
        if (rewardTokenSelectionCount[userCurrentRewardToken[holder]] > 0) {
            rewardTokenSelectionCount[userCurrentRewardToken[holder]] -= 1; // remove count from old token
        }
        userCurrentRewardToken[holder] = address(0);
        userCurrentRewardAMM[holder] = address(uniswapV2Router);
        userHasCustomRewardAMM[holder] = false;
    }

    /// @notice Distributes ether to token holders as dividends.
    /// @dev It reverts if the total supply of tokens is 0.
    /// It emits the `DividendsDistributed` event if the amount of received ether is greater than 0.
    /// About undistributed ether:
    ///   In each distribution, there is a small amount of ether not distributed,
    ///     the magnified amount of which is
    ///     `(msg.value * magnitude) % totalSupply()`.
    ///   With a well-chosen `magnitude`, the amount of undistributed ether
    ///     (de-magnified) in a distribution can be less than 1 wei.
    ///   We can actually keep track of the undistributed ether in a distribution
    ///     and try to distribute it in the next distribution,
    ///     but keeping track of such data on-chain costs much more than
    ///     the saved ether, so we don't do that.

    function distributeDividends() public payable override {
        require(totalSupply() > 0);

        if (msg.value > 0) {
            magnifiedDividendPerShare = magnifiedDividendPerShare.add(
                (msg.value).mul(magnitude) / totalSupply()
            );
            emit DividendsDistributed(msg.sender, msg.value);

            totalDividendsDistributed = totalDividendsDistributed.add(
                msg.value
            );
        }
    }

    /// @notice Withdraws the ether distributed to the sender.
    /// @dev It emits a `DividendWithdrawn` event if the amount of withdrawn ether is greater than 0.
    function withdrawDividend() public virtual override {
        _withdrawDividendOfUser(payable(msg.sender));
    }

    /// @notice Withdraws the ether distributed to the sender.
    /// @dev It emits a `DividendWithdrawn` event if the amount of withdrawn ether is greater than 0.
    function _withdrawDividendOfUser(address payable user)
        internal
        returns (uint256)
    {
        uint256 _withdrawableDividend = withdrawableDividendOf(user);
        if (_withdrawableDividend > 0) {
            // if no custom reward token or reward token is blacklisted, send BNB.
            if (
                !userHasCustomRewardToken[user] &&
                !isBlacklistedToken(userCurrentRewardToken[user])
            ) {
                withdrawnDividends[user] = withdrawnDividends[user].add(
                    _withdrawableDividend
                );
                rawBNBWithdrawnDividends[user] = rawBNBWithdrawnDividends[user]
                    .add(_withdrawableDividend);
                emit DividendWithdrawn(user, _withdrawableDividend);
                (bool success, ) = user.call{
                    value: _withdrawableDividend,
                    gas: 3000
                }("");

                if (!success) {
                    withdrawnDividends[user] = withdrawnDividends[user].sub(
                        _withdrawableDividend
                    );
                    rawBNBWithdrawnDividends[user] = rawBNBWithdrawnDividends[
                        user
                    ].sub(_withdrawableDividend);
                    return 0;
                }
                return _withdrawableDividend;

                // the reward is a token, not BNB, use an IERC20 buyback instead!
            } else {
                withdrawnDividends[user] = withdrawnDividends[user].add(
                    _withdrawableDividend
                );
                emit DividendWithdrawn(user, _withdrawableDividend);
                return swapETHForTokens(user, _withdrawableDividend);
            }
        }
        return 0;
    }

    /// @notice View the amount of dividend in wei that an address can withdraw.
    /// @param _owner The address of a token holder.
    /// @return The amount of dividend in wei that `_owner` can withdraw.
    function dividendOf(address _owner) public view override returns (uint256) {
        return withdrawableDividendOf(_owner);
    }

    /// @notice View the amount of dividend in wei that an address can withdraw.
    /// @param _owner The address of a token holder.
    /// @return The amount of dividend in wei that `_owner` can withdraw.
    function withdrawableDividendOf(address _owner)
        public
        view
        override
        returns (uint256)
    {
        return accumulativeDividendOf(_owner).sub(withdrawnDividends[_owner]);
    }

    /// @notice View the amount of dividend in wei that an address has withdrawn.
    /// @param _owner The address of a token holder.
    /// @return The amount of dividend in wei that `_owner` has withdrawn.
    function withdrawnDividendOf(address _owner)
        public
        view
        override
        returns (uint256)
    {
        return withdrawnDividends[_owner];
    }

    /// @notice View the amount of dividend in wei that an address has earned in total.
    /// @dev accumulativeDividendOf(_owner) = withdrawableDividendOf(_owner) + withdrawnDividendOf(_owner)
    /// = (magnifiedDividendPerShare * balanceOf(_owner) + magnifiedDividendCorrections[_owner]) / magnitude
    /// @param _owner The address of a token holder.
    /// @return The amount of dividend in wei that `_owner` has earned in total.
    function accumulativeDividendOf(address _owner)
        public
        view
        override
        returns (uint256)
    {
        return
            magnifiedDividendPerShare
                .mul(balanceOf(_owner))
                .toInt256Safe()
                .add(magnifiedDividendCorrections[_owner])
                .toUint256Safe() / magnitude;
    }

    /// @dev Internal function that transfer tokens from one address to another.
    /// Update magnifiedDividendCorrections to keep dividends unchanged.
    /// @param from The address to transfer from.
    /// @param to The address to transfer to.
    /// @param value The amount to be transferred.
    function _transfer(
        address from,
        address to,
        uint256 value
    ) internal virtual override {
        require(false);

        int256 _magCorrection = magnifiedDividendPerShare
            .mul(value)
            .toInt256Safe();
        magnifiedDividendCorrections[from] = magnifiedDividendCorrections[from]
            .add(_magCorrection);
        magnifiedDividendCorrections[to] = magnifiedDividendCorrections[to].sub(
            _magCorrection
        );
    }

    /// @dev Internal function that mints tokens to an account.
    /// Update magnifiedDividendCorrections to keep dividends unchanged.
    /// @param account The account that will receive the created tokens.
    /// @param value The amount that will be created.
    function _mint(address account, uint256 value) internal override {
        super._mint(account, value);

        magnifiedDividendCorrections[account] = magnifiedDividendCorrections[
            account
        ].sub((magnifiedDividendPerShare.mul(value)).toInt256Safe());
    }

    /// @dev Internal function that burns an amount of the token of a given account.
    /// Update magnifiedDividendCorrections to keep dividends unchanged.
    /// @param account The account whose tokens will be burnt.
    /// @param value The amount that will be burnt.
    function _burn(address account, uint256 value) internal override {
        super._burn(account, value);

        magnifiedDividendCorrections[account] = magnifiedDividendCorrections[
            account
        ].add((magnifiedDividendPerShare.mul(value)).toInt256Safe());
    }

    function _setBalance(address account, uint256 newBalance) internal {
        uint256 currentBalance = balanceOf(account);

        if (newBalance > currentBalance) {
            uint256 mintAmount = newBalance.sub(currentBalance);
            _mint(account, mintAmount);
        } else if (newBalance < currentBalance) {
            uint256 burnAmount = currentBalance.sub(newBalance);
            _burn(account, burnAmount);
        }
    }
}