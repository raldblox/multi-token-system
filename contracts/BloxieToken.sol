// SPDX-License-Identifier: MIT

pragma solidity ^0.8.10;

/*
 * @dev Provides information about the current execution context, including the
 * sender of the transaction and its data. While these are generally available
 * via msg.sender and msg.data, they should not be accessed in such a direct
 * manner, since when dealing with meta-transactions the account sending and
 * paying for execution may not be the actual sender (as far as an application
 * is concerned).
 *
 * This contract is only required for intermediate, library-like contracts.
 */

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "./library/IterableMapping.sol";

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "./interface/DividendPayingTokenInterface.sol";
import "./interface/IUniswapV2Factory.sol";
import "./interface/IUniswapV2Router02.sol";
import "./BloxieDividendTracker.sol";


contract Bloxie is ERC20, Ownable2Step {
    using SafeMath for uint256;

    IUniswapV2Router02 public uniswapV2Router;
    address public immutable uniswapV2Pair;

    bool private swapping;

    BloxieDividendTracker public dividendTracker;

    mapping(address => uint256) public holderBNBUsedForBuyBacks;

    address public liquidityWallet;
    address public operationsWallet;
    address public migrationSwapContract;
    address private buyBackWallet;

    uint256 public maxSellTransactionAmount = 10000000 * decimals(); // @note Equals 1e+25 | 10,000,000

    uint256 public swapTokensAtAmount = 100000 * decimals(); // @note Equals 1e+23 | 100,000

    // Anti-bot and anti-whale mappings and variables for launch
    mapping(address => uint256) private _holderLastTransferTimestamp; // Hold the last Transfer temporarily during launch

    // @note For the launch, enable transfer delays
    bool public transferDelayEnabled = true;

    // Airdrop limits to prevent airdrop dump to protect new investors
    mapping(address => uint256) public _airDropAddressNextSellDate;
    mapping(address => uint256) public _airDropTokensRemaining;
    uint256 public airDropLimitLiftDate;
    bool public airDropLimitInEffect;
    mapping(address => bool) public _isAirdoppedWallet;
    mapping(address => uint256) public _airDroppedTokenAmount;
    uint256 public airDropDailySellPerc = 1; // @note Disabled airDrop

    // Track last sell to reduce sell penalty over time by 10% per week the holder sells *no* tokens
    mapping(address => uint256) public _holderLastSellDate;

    // Fees @note Updated fees
    uint256 public BNBRewardsFee = 19;
    uint256 public liquidityFee = 4;
    uint256 public totalFees = BNBRewardsFee.add(liquidityFee);
    uint256 public operationsFee = 1; // This is a subset of the liquidity fee, not in addition to. operations fee + buyback fee cannot be higher than liquidity fee.
    uint256 public buyBackFee = 2;

    // Sells have fees of 4.8 and 12 (16.8 total) (4 * 1.2 and 10 * 1.2)
    uint256 public immutable sellFeeIncreaseFactor = 100; // @note Disabled sell fee increase factor

    // Use by default 300,000 gas to process auto-claiming dividends
    uint256 public gasForProcessing = 300000;

    // @note tradingIsEnabled
    uint256 public immutable tradingEnabledTimestamp = 1670415311; // @note tradingIsEnabled
    mapping(address => bool) private canTransferBeforeTradingIsEnabled;

    // Exlcude from fees and max transaction amount
    mapping(address => bool) private _isExcludedFromFees;

    // Store addresses that a automatic market maker pairs. Any transfer *to* these addresses
    // could be subject to a maximum transfer amount
    mapping(address => bool) public automatedMarketMakerPairs;

    event UpdateDividendTracker(
        address indexed newAddress,
        address indexed oldAddress
    );
    event UpdateUniswapV2Router(
        address indexed newAddress,
        address indexed oldAddress
    );
    event ExcludeFromFees(address indexed account, bool isExcluded);
    event ExcludeMultipleAccountsFromFees(address[] accounts, bool isExcluded);
    event SetAutomatedMarketMakerPair(address indexed pair, bool indexed value);
    event BuyBackWithNoFees(address indexed holder, uint256 indexed bnbSpent);
    event LiquidityWalletUpdated(
        address indexed newLiquidityWallet,
        address indexed oldLiquidityWallet
    );
    event OperationsWalletUpdated(
        address indexed newLiquidityWallet,
        address indexed oldLiquidityWallet
    );
    event MigrationSwapContractUpdated(
        address indexed newMigrationSwapContract,
        address indexed oldMigrationSwapContract
    );
    event BuyBackWalletUpdated(
        address indexed newLiquidityWallet,
        address indexed oldLiquidityWallet
    );
    event FeesUpdated(
        uint256 indexed newBNBRewardsFee,
        uint256 indexed newLiquidityFee,
        uint256 newOperationsFee,
        uint256 newBuyBackFee
    );
    event GasForProcessingUpdated(
        uint256 indexed newValue,
        uint256 indexed oldValue
    );

    event SwapAndLiquify(
        uint256 tokensSwapped,
        uint256 ethReceived,
        uint256 tokensIntoLiqudity
    );

    event SendDividends(uint256 tokensSwapped, uint256 amount);

    event ProcessedDividendTracker(
        uint256 iterations,
        uint256 claims,
        uint256 lastProcessedIndex,
        bool indexed automatic,
        uint256 gas,
        address indexed processor
    );

    constructor() ERC20("Bloxie", "BLOX") {
        dividendTracker = new BloxieDividendTracker();

        liquidityWallet = owner();
        operationsWallet = owner();
        buyBackWallet = owner();

        // @note Router address for PancakeSwap v2 (LIVE) @note enabled
        IUniswapV2Router02 _uniswapV2Router = IUniswapV2Router02(
            0x10ED43C718714eb63d5aA57B78B54704E256024E
        );

        // Create a uniswap pair for this new token
        address _uniswapV2Pair = IUniswapV2Factory(_uniswapV2Router.factory())
            .createPair(address(this), _uniswapV2Router.WETH());

        uniswapV2Router = _uniswapV2Router;
        uniswapV2Pair = _uniswapV2Pair;

        airDropLimitLiftDate = block.timestamp + 10 minutes; // @note 10 minute restrictions on Air Drop recipients

        airDropLimitInEffect = false; // @note AirDrop Disabled

        // @note migrationSwapContract
        address _migrationSwapContract = 0xD152f549545093347A162Dce210e7293f1452150;
        migrationSwapContract = _migrationSwapContract;

        _setAutomatedMarketMakerPair(_uniswapV2Pair, true);

        // Exclude from receiving dividends
        dividendTracker.excludeFromDividends(address(dividendTracker));
        dividendTracker.excludeFromDividends(address(this));
        dividendTracker.excludeFromDividends(liquidityWallet);
        dividendTracker.excludeFromDividends(
            address(0x000000000000000000000000000000000000dEaD)
        );
        dividendTracker.excludeFromDividends(address(_uniswapV2Router));

        // @note migrationSwapContract
        dividendTracker.excludeFromDividends(migrationSwapContract);

        // Exclude from paying fees or having max transaction amount
        excludeFromFees(liquidityWallet, true);
        excludeFromFees(address(this), true);
        excludeFromFees(address(dividendTracker), true);
        excludeFromFees(address(operationsWallet), true);
        excludeFromFees(address(buyBackWallet), true);

        // @note migrationSwapContract
        excludeFromFees(address(migrationSwapContract), true);

        // @note tradingIsEnabled
        canTransferBeforeTradingIsEnabled[owner()] = true;
        canTransferBeforeTradingIsEnabled[migrationSwapContract] = true;

        /*
            _mint is an internal function in ERC20.sol that is only called here,
            and CANNOT be called ever again
        */
        _mint(owner(), 1000000000 * decimals()); // @note Equals 1e+27 | Set supply to 1,000,000,000
    }

    receive() external payable {}

    // Enable / disable custom AMMs
    function setWhiteListAMM(address ammAddress, bool isWhiteListed)
        external
        onlyOwner
    {
        require(
            isContract(ammAddress),
            "Bloxie: setWhiteListAMM:: AMM is a wallet, not a contract"
        );
        dividendTracker.setWhiteListAMM(ammAddress, isWhiteListed);
    }

    // Change the minimum amount of tokens to sell from fees
    function updateSwapTokensAtAmount(uint256 newAmount)
        external
        onlyOwner
        returns (bool)
    {
        require(
            newAmount < totalSupply(),
            "Swap amount cannot be higher than total supply."
        );
        swapTokensAtAmount = newAmount;
        return true;
    }

    // Remove transfer delay after launch
    function disableTransferDelay() external onlyOwner {
        transferDelayEnabled = false;
    }

    // Update dividend tracker
    function updateDividendTracker(address newAddress) public onlyOwner {
        require(
            newAddress != address(dividendTracker),
            "Bloxie: The dividend tracker already has that address"
        );

        BloxieDividendTracker newDividendTracker = BloxieDividendTracker(
            payable(newAddress)
        );

        require(
            newDividendTracker.owner() == address(this),
            "Bloxie: The new dividend tracker must be owned by the Bloxie token contract"
        );

        newDividendTracker.excludeFromDividends(address(newDividendTracker));
        newDividendTracker.excludeFromDividends(address(this));
        newDividendTracker.excludeFromDividends(owner());
        newDividendTracker.excludeFromDividends(address(uniswapV2Router));

        emit UpdateDividendTracker(newAddress, address(dividendTracker));

        dividendTracker = newDividendTracker;
    }

    // updates the maximum amount of tokens that can be bought or sold by holders
    function updateMaxTxn(uint256 maxTxnAmount) external onlyOwner {
        maxSellTransactionAmount = maxTxnAmount;
    }

    // Updates the minimum amount of tokens people must hold in order to get dividends
    function updateDividendTokensMinimum(uint256 minimumToEarnDivs)
        external
        onlyOwner
    {
        dividendTracker.updateDividendMinimum(minimumToEarnDivs);
    }

    // Updates the default router for selling tokens
    function updateUniswapV2Router(address newAddress) external onlyOwner {
        require(
            newAddress != address(uniswapV2Router),
            "Bloxie: The router already has that address"
        );
        emit UpdateUniswapV2Router(newAddress, address(uniswapV2Router));
        uniswapV2Router = IUniswapV2Router02(newAddress);
    }

    // Updates the default router for buying tokens from dividend tracker
    function updateDividendUniswapV2Router(address newAddress)
        external
        onlyOwner
    {
        dividendTracker.updateDividendUniswapV2Router(newAddress);
    }

    // Excludes wallets from max txn and fees.
    function excludeFromFees(address account, bool excluded) public onlyOwner {
        _isExcludedFromFees[account] = excluded;
        emit ExcludeFromFees(account, excluded);
    }

    // Allows multiple exclusions at once
    function excludeMultipleAccountsFromFees(
        address[] calldata accounts,
        bool excluded
    ) external onlyOwner {
        for (uint256 i = 0; i < accounts.length; i++) {
            _isExcludedFromFees[accounts[i]] = excluded;
        }

        emit ExcludeMultipleAccountsFromFees(accounts, excluded);
    }

    // Excludes wallets and contracts from dividends (such as CEX hotwallets, etc.)
    function excludeFromDividends(address account) external onlyOwner {
        dividendTracker.excludeFromDividends(account);
    }

    // Removes exclusion on wallets and contracts from dividends (such as CEX hotwallets, etc.)
    function includeInDividends(address account) external onlyOwner {
        dividendTracker.includeInDividends(account);
    }

    // Allow adding additional AMM pairs to the list
    function setAutomatedMarketMakerPair(address pair, bool value)
        external
        onlyOwner
    {
        require(
            pair != uniswapV2Pair,
            "Bloxie: The PancakeSwap pair cannot be removed from automatedMarketMakerPairs"
        );

        _setAutomatedMarketMakerPair(pair, value);
    }

    // For one-time airdrop feature after contract launch
    function airdropToWallets(
        address[] memory airdropWallets,
        uint256[] memory amount
    ) external onlyOwner {
        require(
            airdropWallets.length == amount.length,
            "Bloxie: airdropToWallets:: Arrays must be the same length"
        );
        for (uint256 i = 0; i < airdropWallets.length; i++) {
            address wallet = airdropWallets[i];
            uint256 airdropAmount = amount[i];
            if (_isAirdoppedWallet[wallet] == false && !isContract(wallet)) {
                // prevent double sending and don't airdrop contracts, only wallets.
                _isAirdoppedWallet[wallet] = true;
                _airDroppedTokenAmount[wallet] = airdropAmount;
                _airDropTokensRemaining[wallet] = airdropAmount;
                _airDropAddressNextSellDate[wallet] = block.timestamp.sub(1);
                _transfer(msg.sender, wallet, airdropAmount);
            }
        }
    }

    // Sets the wallet that receives LP tokens to lock
    function updateLiquidityWallet(address newLiquidityWallet)
        external
        onlyOwner
    {
        require(
            newLiquidityWallet != liquidityWallet,
            "Bloxie: The liquidity wallet is already this address"
        );
        excludeFromFees(newLiquidityWallet, true);
        emit LiquidityWalletUpdated(newLiquidityWallet, liquidityWallet);
        liquidityWallet = newLiquidityWallet;
    }

    // Updates the operations wallet (marketing, charity, etc.)
    function updateOperationsWallet(address newOperationsWallet)
        external
        onlyOwner
    {
        require(
            newOperationsWallet != operationsWallet,
            "Bloxie: The operations wallet is already this address"
        );
        excludeFromFees(newOperationsWallet, true);
        emit OperationsWalletUpdated(newOperationsWallet, operationsWallet);
        operationsWallet = newOperationsWallet;
    }

    // @note migrationSwapContract
    function updateMigrationSwapContract(address newMigrationSwapContract)
        external
        onlyOwner
    {
        require(
            newMigrationSwapContract != migrationSwapContract,
            "Bloxie: The migration swap contract is already this address"
        );
        excludeFromFees(newMigrationSwapContract, true);
        canTransferBeforeTradingIsEnabled[newMigrationSwapContract] = true; // @note tradingIsEnabled
        emit MigrationSwapContractUpdated(
            newMigrationSwapContract,
            migrationSwapContract
        );
        migrationSwapContract = newMigrationSwapContract;
    }

    // Updates the wallet used for manual buybacks.
    function updateBuyBackWallet(address newBuyBackWallet) external onlyOwner {
        require(
            newBuyBackWallet != buyBackWallet,
            "Bloxie: The buyback wallet is already this address"
        );
        excludeFromFees(newBuyBackWallet, true);
        emit BuyBackWalletUpdated(newBuyBackWallet, buyBackWallet);
        buyBackWallet = newBuyBackWallet;
    }

    // Rebalance fees as needed
    function updateFees(
        uint256 bnbRewardPerc,
        uint256 liquidityPerc,
        uint256 operationsPerc,
        uint256 buyBackPerc
    ) external onlyOwner {
        require(
            operationsPerc.add(buyBackPerc) <= liquidityPerc,
            "Bloxie: updateFees:: Liquidity Perc must be equal to or higher than operations and buyback combined."
        );
        emit FeesUpdated(
            bnbRewardPerc,
            liquidityPerc,
            operationsPerc,
            buyBackPerc
        );
        BNBRewardsFee = bnbRewardPerc;
        liquidityFee = liquidityPerc;
        operationsFee = operationsPerc;
        buyBackFee = buyBackPerc;
        totalFees = BNBRewardsFee.add(liquidityFee);
    }

    // Changes the gas reserve for processing dividend distribution
    function updateGasForProcessing(uint256 newValue) external onlyOwner {
        require(
            newValue >= 200000 && newValue <= 500000,
            "Bloxie: gasForProcessing must be between 200,000 and 500,000"
        );
        require(
            newValue != gasForProcessing,
            "Bloxie: Cannot update gasForProcessing to same value"
        );
        emit GasForProcessingUpdated(newValue, gasForProcessing);
        gasForProcessing = newValue;
    }

    // Changes the amount of time to wait for claims (1-24 hours, expressed in seconds)
    function updateClaimWait(uint256 claimWait)
        external
        onlyOwner
        returns (bool)
    {
        dividendTracker.updateClaimWait(claimWait);
        return true;
    }

    function setBlacklistToken(address tokenAddress, bool isBlacklisted)
        external
        onlyOwner
        returns (bool)
    {
        dividendTracker.setBlacklistToken(tokenAddress, isBlacklisted);
        return true;
    }

    // Determines if an AMM can be used for rewards
    function isAMMWhitelisted(address ammAddress) public view returns (bool) {
        return dividendTracker.ammIsWhiteListed(ammAddress);
    }

    function isContract(address account) internal view returns (bool) {
        // According to EIP-1052, 0x0 is the value returned for not-yet created accounts
        // and 0xc5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470 is returned
        // for accounts without code, i.e. `keccak256('')`
        bytes32 codehash;
        bytes32 accountHash = 0xc5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470;
        // solhint-disable-next-line no-inline-assembly
        assembly {
            codehash := extcodehash(account)
        }
        return (codehash != accountHash && codehash != 0x0);
    }

    function getUserCurrentRewardToken(address holder)
        public
        view
        returns (address)
    {
        return dividendTracker.userCurrentRewardToken(holder);
    }

    function getUserHasCustomRewardToken(address holder)
        public
        view
        returns (bool)
    {
        return dividendTracker.userHasCustomRewardToken(holder);
    }

    function getRewardTokenSelectionCount(address token)
        public
        view
        returns (uint256)
    {
        return dividendTracker.rewardTokenSelectionCount(token);
    }

    function getLastProcessedIndex() external view returns (uint256) {
        return dividendTracker.getLastProcessedIndex();
    }

    function getNumberOfDividendTokenHolders() external view returns (uint256) {
        return dividendTracker.getNumberOfTokenHolders();
    }

    // Returns a number between 50 and 120 that determines the penalty a user pays on sells
    function getHolderSellFactor(address holder) public view returns (uint256) {
        // Get time since last sell measured in 2 week increments
        uint256 timeSinceLastSale = (
            block.timestamp.sub(_holderLastSellDate[holder])
        ).div(2 weeks);

        // Protection in case someone tries to use a contract to facilitate buys/sells
        if (_holderLastSellDate[holder] == 0) {
            return sellFeeIncreaseFactor;
        }

        // Cap the sell factor cooldown to 14 weeks and 50% of sell tax
        if (timeSinceLastSale >= 7) {
            return 50; // 50% sell factor is minimum
        }

        // Return the fee factor minus the number of weeks since sale * 10.  SellFeeIncreaseFactor is immutable at 120 so the most this can subtract is 6*10 = 120 - 60 = 60%
        return sellFeeIncreaseFactor - (timeSinceLastSale.mul(10));
    }

    function getDividendTokensMinimum() external view returns (uint256) {
        return dividendTracker.minimumTokenBalanceForDividends();
    }

    function getWalletMaxAirdropSell(address holder)
        public
        view
        returns (uint256)
    {
        if (airDropLimitInEffect) {
            return
                _airDroppedTokenAmount[holder].mul(airDropDailySellPerc).div(
                    100
                );
        }
        return _airDropTokensRemaining[holder];
    }

    // User Tokens they can currently sell (expose in UI if possible)
    function getWalletTokensAvailableToSell(address holder)
        external
        view
        returns (uint256)
    {
        uint256 balance = balanceOf(holder);
        uint256 deltaBalance = balance;
        if (airDropLimitInEffect) {
            if (_airDropTokensRemaining[holder] <= balance) {
                deltaBalance = balance.sub(_airDropTokensRemaining[holder]);
            }
            if (block.timestamp <= _airDropAddressNextSellDate[holder]) {
                // Available airdrop tokens plus all purchased tokens
                return deltaBalance.add(getWalletMaxAirdropSell(holder));
            }
        }
        return deltaBalance;
    }

    function getClaimWait() external view returns (uint256) {
        return dividendTracker.claimWait();
    }

    function getTotalDividendsDistributed() external view returns (uint256) {
        return dividendTracker.totalDividendsDistributed();
    }

    function isExcludedFromFees(address account) public view returns (bool) {
        return _isExcludedFromFees[account];
    }

    function withdrawableDividendOf(address account)
        public
        view
        returns (uint256)
    {
        return dividendTracker.withdrawableDividendOf(account);
    }

    function dividendTokenBalanceOf(address account)
        public
        view
        returns (uint256)
    {
        return dividendTracker.balanceOf(account);
    }

    function getAccountDividendsInfo(address account)
        external
        view
        returns (
            address,
            int256,
            int256,
            uint256,
            uint256,
            uint256,
            uint256,
            uint256
        )
    {
        return dividendTracker.getAccount(account);
    }

    function getAccountDividendsInfoAtIndex(uint256 index)
        external
        view
        returns (
            address,
            int256,
            int256,
            uint256,
            uint256,
            uint256,
            uint256,
            uint256
        )
    {
        return dividendTracker.getAccountAtIndex(index);
    }

    function getRawBNBDividends(address holder) public view returns (uint256) {
        return dividendTracker.getRawBNBDividends(holder);
    }

    function getBNBAvailableForHolderBuyBack(address holder)
        public
        view
        returns (uint256)
    {
        return
            getRawBNBDividends(holder).sub(
                holderBNBUsedForBuyBacks[msg.sender]
            );
    }

    function isBlacklistedToken(address tokenAddress)
        public
        view
        returns (bool)
    {
        return dividendTracker.isBlacklistedToken(tokenAddress);
    }

    // Set the reward token for the user
    function setRewardToken(address rewardTokenAddress) public returns (bool) {
        require(
            isContract(rewardTokenAddress),
            "Bloxie: setRewardToken:: Address is a wallet, not a contract."
        );
        require(
            rewardTokenAddress != address(this),
            "Bloxie: setRewardToken:: Cannot set reward token as this token due to Router limitations."
        );
        require(
            !isBlacklistedToken(rewardTokenAddress),
            "Bloxie: setRewardToken:: Reward Token is blacklisted from being used as rewards."
        );
        dividendTracker.setRewardToken(
            msg.sender,
            rewardTokenAddress,
            address(uniswapV2Router)
        );
        return true;
    }

    // Set the reward token for the user with a custom AMM (AMM must be whitelisted)
    function setRewardTokenWithCustomAMM(
        address rewardTokenAddress,
        address ammContractAddress
    ) public returns (bool) {
        require(
            isContract(rewardTokenAddress),
            "Bloxie: setRewardToken:: Address is a wallet, not a contract."
        );
        require(
            ammContractAddress != address(uniswapV2Router),
            "Bloxie: setRewardToken:: Use setRewardToken to use default Router"
        );
        require(
            rewardTokenAddress != address(this),
            "Bloxie: setRewardToken:: Cannot set reward token as this token due to Router limitations."
        );
        require(
            !isBlacklistedToken(rewardTokenAddress),
            "Bloxie: setRewardToken:: Reward Token is blacklisted from being used as rewards."
        );
        require(
            isAMMWhitelisted(ammContractAddress) == true,
            "Bloxie: setRewardToken:: AMM is not whitelisted!"
        );
        dividendTracker.setRewardToken(
            msg.sender,
            rewardTokenAddress,
            ammContractAddress
        );
        return true;
    }

    // Unset the reward token back to BNB
    function unsetRewardToken() public returns (bool) {
        dividendTracker.unsetRewardToken(msg.sender);
        return true;
    }

    // Holders can buyback with no fees up to their claimed raw BNB amount
    function buyBackTokensWithNoFees() external payable returns (bool) {
        uint256 userRawBNBDividends = getRawBNBDividends(msg.sender);
        require(
            userRawBNBDividends >=
                holderBNBUsedForBuyBacks[msg.sender].add(msg.value),
            "Bloxie: buyBackTokensWithNoFees:: Cannot Spend more than earned."
        );

        uint256 ethAmount = msg.value;

        // Generate the pancake pair path of token -> weth
        address[] memory path = new address[](2);
        path[0] = uniswapV2Router.WETH();
        path[1] = address(this);

        // Update amount to prevent user from buying with more BNB than they've received as raw rewards (also update before transfer to prevent reentrancy)
        holderBNBUsedForBuyBacks[msg.sender] = holderBNBUsedForBuyBacks[
            msg.sender
        ].add(msg.value);

        bool prevExclusion = _isExcludedFromFees[msg.sender]; // ensure we don't remove exclusions if the current wallet is already excluded

        // Make the swap to the contract first to bypass fees
        _isExcludedFromFees[msg.sender] = true;

        uniswapV2Router.swapExactETHForTokensSupportingFeeOnTransferTokens{
            value: ethAmount
        }( // try to swap for tokens, if it fails (bad contract, or whatever other reason, send BNB)
            0, // accept any amount of Tokens
            path,
            address(msg.sender),
            block.timestamp + 360
        );

        _isExcludedFromFees[msg.sender] = prevExclusion; // set value to match original value

        emit BuyBackWithNoFees(msg.sender, ethAmount);

        return true;
    }

    // Allows a user to manually claim their tokens
    function claim() external {
        dividendTracker.processAccount(payable(msg.sender), false);
    }

    // Allow a user to manuall process dividends
    function processDividendTracker(uint256 gas) external {
        (
            uint256 iterations,
            uint256 claims,
            uint256 lastProcessedIndex
        ) = dividendTracker.process(gas);
        emit ProcessedDividendTracker(
            iterations,
            claims,
            lastProcessedIndex,
            false,
            gas,
            tx.origin
        );
    }

    // @dev Token functions
    function _setAutomatedMarketMakerPair(address pair, bool value) private {
        require(
            automatedMarketMakerPairs[pair] != value,
            "Bloxie: Automated market maker pair is already set to that value"
        );
        automatedMarketMakerPairs[pair] = value;

        if (value) {
            dividendTracker.excludeFromDividends(pair);
        }
        emit SetAutomatedMarketMakerPair(pair, value);
    }

    // @note tradingIsEnabled
    function getTradingIsEnabled() public view returns (bool) {
        return block.timestamp >= tradingEnabledTimestamp;
    }

    // @note Transfer
    function _transfer(
        address from,
        address to,
        uint256 amount
    ) internal override {
        // Require a valid address for transfers
        require(from != address(0), "ERC20: transfer from the zero address");
        require(to != address(0), "ERC20: transfer to the zero address");

        // @note tradingIsEnabled
        bool tradingIsEnabled = getTradingIsEnabled();
        if (!tradingIsEnabled) {
            require(
                canTransferBeforeTradingIsEnabled[from],
                "_transfer:: cannot send until trading is enabled"
            );
        }

        // Early exit with no other logic if transfering 0 (to prevent 0 transfers from triggering other logic)
        if (amount == 0) {
            super._transfer(from, to, 0);
            return;
        }

        // @note Transfer delay enabled
        // Prevent buying more than 1 txn per block at launch, bot killer
        if (transferDelayEnabled) {
            if (
                to != owner() &&
                to != address(uniswapV2Router) &&
                to != address(uniswapV2Pair) &&
                !_isExcludedFromFees[to] &&
                !_isExcludedFromFees[from]
            ) {
                require(
                    _holderLastTransferTimestamp[to] < block.timestamp,
                    "_transfer:: Transfer Delay enabled.  Please try again later."
                );
                _holderLastTransferTimestamp[to] = block.timestamp;
            }
        }

        // @note Holder sell factor penalty
        // Set the last sell date to first purchase date for new wallet
        if (!isContract(to) && !_isExcludedFromFees[to]) {
            if (_holderLastSellDate[to] == 0) {
                _holderLastSellDate[to] == block.timestamp;
            }
        }

        // @note Holder sell factor penalty
        // Update sell date on buys to prevent gaming the decaying sell tax feature.
        // Every buy moves the sell date up 1/3rd of the difference between last sale date and current timestamp
        if (
            !isContract(to) &&
            automatedMarketMakerPairs[from] &&
            !_isExcludedFromFees[to]
        ) {
            if (_holderLastSellDate[to] >= block.timestamp) {
                _holderLastSellDate[to] = _holderLastSellDate[to].add(
                    block.timestamp.sub(_holderLastSellDate[to]).div(3)
                );
            }
        }

        if (
            !swapping &&
            tradingIsEnabled && // @note tradingIsEnabled
            from != address(uniswapV2Router) && // Router -> pair is removing liquidity which shouldn't have max
            !_isExcludedFromFees[to] && // No max (to) those excluded from fees
            !_isExcludedFromFees[from] // No max (from) those excluded from fees
        ) {
            require(
                amount <= maxSellTransactionAmount,
                "_transfer:: Transfer amount exceeds the maxSellTransactionAmount."
            );
        }

        // @note Airdrop limits
        if (airDropLimitInEffect) {
            // Check if Limit is in effect
            if (airDropLimitLiftDate <= block.timestamp) {
                airDropLimitInEffect = false; // Set the limit to false if the limit date has been exceeded
            } else {
                uint256 senderBalance = balanceOf(from); // Get total token balance of sender
                if (
                    _isAirdoppedWallet[from] &&
                    senderBalance.sub(amount) < _airDropTokensRemaining[from]
                ) {
                    require(
                        _airDropAddressNextSellDate[from] <= block.timestamp &&
                            block.timestamp >= airDropLimitLiftDate.sub(9 days),
                        "_transfer:: White List Wallet cannot sell whitelist tokens until next sell date. Please read the contract for your next sale date."
                    );
                    uint256 airDropMaxSell = getWalletMaxAirdropSell(from); // Airdrop 10% max sell of total airdropped tokens per day for 10 days

                    // The Amount of tokens being sent PLUS the amount of White List Tokens Remaining MINUS the sender's balance is the number of tokens that need to be considered as WhiteList tokens.
                    // This checks a few lines up to ensure there is no subtraction overflows, so it can never be a negative value.
                    uint256 tokensToSubtract = amount
                        .add(_airDropTokensRemaining[from])
                        .sub(senderBalance);

                    require(
                        tokensToSubtract <= airDropMaxSell,
                        "_transfer:: May not sell more than 10% of White List tokens in a single day until the White List Limit is lifted."
                    );
                    _airDropTokensRemaining[from] = _airDropTokensRemaining[
                        from
                    ].sub(tokensToSubtract);
                    _airDropAddressNextSellDate[from] =
                        block.timestamp +
                        (1 days *
                            (tokensToSubtract.mul(100).div(airDropMaxSell))) /
                        100; // Only push out timer as a % of the transfer, so 5% could be sold in 1% chunks over the course of a day, for example.
                }
            }
        }

        uint256 contractTokenBalance = balanceOf(address(this));

        bool canSwap = contractTokenBalance >= swapTokensAtAmount;

        if (
            tradingIsEnabled && // @note tradingIsEnabled
            canSwap &&
            !swapping &&
            !automatedMarketMakerPairs[from] &&
            from != liquidityWallet &&
            to != liquidityWallet &&
            from != operationsWallet &&
            to != operationsWallet &&
            from != migrationSwapContract && // @note migrationSwapContract
            to != migrationSwapContract && // @note migrationSwapContract
            from != buyBackWallet &&
            to != buyBackWallet &&
            !_isExcludedFromFees[to] &&
            !_isExcludedFromFees[from] &&
            from != address(this) &&
            from != address(dividendTracker)
        ) {
            swapping = true;

            uint256 swapTokens = contractTokenBalance.mul(liquidityFee).div(
                totalFees
            );
            swapAndLiquify(swapTokens);

            uint256 sellTokens = balanceOf(address(this));
            swapAndSendDividends(sellTokens);

            swapping = false;
        }

        // @note tradingIsEnabled & takeFee
        bool takeFee = tradingIsEnabled && !swapping;

        // if any account belongs to _isExcludedFromFee account then remove the fee
        if (
            _isExcludedFromFees[from] ||
            _isExcludedFromFees[to] ||
            from == address(this)
        ) {
            takeFee = false;
        }

        // @note Remove fees for buys (only enabled on sells)
        if (automatedMarketMakerPairs[from]) {
            takeFee = false;
        }

        if (takeFee) {
            uint256 fees = amount.mul(totalFees).div(100);

            // @note holderSellFactor penalty
            // If sell, multiply by holderSellFactor (decaying sell penalty by 10% every 2 weeks without selling)
            if (automatedMarketMakerPairs[to]) {
                fees = fees.mul(getHolderSellFactor(from)).div(100);
                _holderLastSellDate[from] = block.timestamp; // update last sale date on sell
            }

            amount = amount.sub(fees);

            super._transfer(from, address(this), fees);
        }

        super._transfer(from, to, amount);

        try
            dividendTracker.setBalance(payable(from), balanceOf(from))
        {} catch {}
        try dividendTracker.setBalance(payable(to), balanceOf(to)) {} catch {}

        if (!swapping) {
            uint256 gas = gasForProcessing;

            try dividendTracker.process(gas) returns (
                uint256 iterations,
                uint256 claims,
                uint256 lastProcessedIndex
            ) {
                emit ProcessedDividendTracker(
                    iterations,
                    claims,
                    lastProcessedIndex,
                    true,
                    gas,
                    tx.origin
                );
            } catch {}
        }
    }

    // Split the contract balance into proper pieces
    // figure out how many tokens should be sold for liquidity vs operations / buybacks
    function swapAndLiquify(uint256 tokens) private {
        if (liquidityFee > 0) {
            uint256 tokensForLiquidity;

            if (liquidityFee > 0) {
                tokensForLiquidity = tokens
                    .mul(liquidityFee.sub(buyBackFee.add(operationsFee)))
                    .div(liquidityFee);
            } else {
                tokensForLiquidity = 0;
            }

            uint256 tokensForBuyBackAndOperations = tokens.sub(
                tokensForLiquidity
            );

            uint256 half = tokensForLiquidity.div(2);
            uint256 otherHalf = tokensForLiquidity.sub(half);

            // Capture the contract's current ETH balance.
            // this is so that we can capture exactly the amount of ETH that the
            // swap creates, and not make the liquidity event include any ETH that
            // has been manually sent to the contract
            uint256 initialBalance = address(this).balance;

            // Swap tokens for ETH
            swapTokensForEth(half); // <- this breaks the ETH -> HATE swap when swap+liquify is triggered

            // How much ETH did we just swap into?
            uint256 newBalance = address(this).balance.sub(initialBalance);

            // Add liquidity to uniswap
            addLiquidity(otherHalf, newBalance);

            swapTokensForEth(tokensForBuyBackAndOperations);

            uint256 balanceForOperationsAndBuyBack = address(this).balance.sub(
                initialBalance
            );

            bool success;

            if (operationsFee > 0) {
                // Send to Operations Wallet
                uint256 operationsBalance = balanceForOperationsAndBuyBack
                    .mul(operationsFee)
                    .div(buyBackFee.add(operationsFee));
                (success, ) = payable(operationsWallet).call{
                    value: operationsBalance
                }("");
                require(
                    success,
                    "Bloxie: SwapAndLiquify:: Unable to send BNB to Operations Wallet"
                );
            }

            if (buyBackFee > 0) {
                // Send to BuyBack Wallet
                uint256 buyBackBalance = balanceForOperationsAndBuyBack
                    .mul(buyBackFee)
                    .div(buyBackFee.add(operationsFee));
                (success, ) = payable(buyBackWallet).call{
                    value: buyBackBalance
                }("");
                require(
                    success,
                    "Bloxie: SwapAndLiquify:: Unable to send BNB to BuyBack Wallet"
                );
            }

            emit SwapAndLiquify(half, newBalance, otherHalf);
        }
    }

    function swapTokensForEth(uint256 tokenAmount) private {
        // Generate the uniswap pair path of token -> weth
        address[] memory path = new address[](2);
        path[0] = address(this);
        path[1] = uniswapV2Router.WETH();

        _approve(address(this), address(uniswapV2Router), tokenAmount);

        // Make the swap
        uniswapV2Router.swapExactTokensForETHSupportingFeeOnTransferTokens(
            tokenAmount,
            0,
            path,
            address(this),
            block.timestamp
        );
    }

    function addLiquidity(uint256 tokenAmount, uint256 ethAmount) private {
        // Approve token transfer to cover all possible scenarios
        _approve(address(this), address(uniswapV2Router), tokenAmount);

        // Add the liquidity
        uniswapV2Router.addLiquidityETH{value: ethAmount}(
            address(this),
            tokenAmount,
            0,
            0,
            liquidityWallet,
            block.timestamp
        );
    }

    function swapAndSendDividends(uint256 tokens) private {
        swapTokensForEth(tokens);
        uint256 dividends = address(this).balance;
        (bool success, ) = address(dividendTracker).call{value: dividends}("");

        if (success) {
            emit SendDividends(tokens, dividends);
        }
    }
}