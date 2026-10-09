// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {PullPayments} from "./PullPayments.sol";
import {IWETH} from "./interfaces/IPawn.sol";

/// @notice WETH shares backed by idle WETH and outstanding principal, less segregated funds.
contract LendingPool is ERC4626, Ownable2Step, PullPayments {
    error OnlyPawnShop();
    error InvalidAmount();
    error InsufficientIdle();
    error CapExceeded();
    error TimelockPending();
    error DirectETHDisabled();
    error RenounceDisabled();
    error WindowExpired();

    uint256 public constant DELAY = 48 hours;
    uint256 public constant VESTING = 7 days;
    uint256 public constant EXECUTION_WINDOW = 7 days;
    address public immutable pawnShop;
    uint256 public totalBorrowed;
    uint256 public shortfallReserve;
    uint256 public depositCap = 10 ether;
    uint256 public pendingCap;
    uint256 public pendingCapAt;
    uint256 public cumulativeLoanFees;
    uint256 public cumulativeDonations;
    uint256 public cumulativeLoss;
    uint256 public cumulativeRecoveries;
    uint256 public expectedAuctionLoss;
    mapping(uint256 => uint256) public auctionLoss;
    uint256 public vestingStartIndex;
    /// @notice Reserve consumed by each auction settlement, restored first from late recoveries (F9).
    mapping(uint256 => uint256) public reserveUsed;
    /// @notice Released loss allowance in excess of the realised loss, vesting linearly (F4).
    uint256 public releaseVestingAmount;
    uint256 public releaseVestingStart;

    struct DonationCheckpoint {
        uint64 start;
        uint256 cumulativeAmount;
        uint256 cumulativeUnlockWeight;
    }
    DonationCheckpoint[] public donationCheckpoints;

    event Borrowed(uint256 amount);
    event Settled(uint256 principal, uint256 paid, uint256 reserveUsed, uint256 loss);
    event FeeReceived(uint256 amount);
    event ReserveAdded(uint256 amount);
    event Donated(address indexed donor, uint256 amount, uint256 slot);
    event CapQueued(uint256 cap, uint256 executableAt);
    event CapRaised(uint256 cap);
    event AuctionLossMarked(uint256 indexed loanId, uint256 expectedLoss);
    event RecoveryReceived(uint256 amount);
    event EmptyPoolReserve(uint256 amount);
    event CapCancelled(uint256 cap);
    event AllowanceReleaseVesting(uint256 indexed loanId, uint256 amount, uint256 totalUnvested);
    event ReserveRestored(uint256 indexed loanId, uint256 amount);
    event AllowanceReleaseCancelled(uint256 indexed loanId, uint256 amount, uint256 totalUnvested);

    constructor(address owner_, address weth_, address shop_)
        ERC20("Pawn Lending Share", "pETH")
        ERC4626(IERC20(weth_))
        Ownable(owner_)
    {
        if (weth_ == address(0) || shop_ == address(0)) revert InvalidRecipient();
        pawnShop = shop_;
    }

    modifier onlyShop() {
        if (msg.sender != pawnShop) revert OnlyPawnShop();
        _;
    }

    function renounceOwnership() public view override onlyOwner {
        revert RenounceDisabled();
    }

    function _decimalsOffset() internal pure override returns (uint8) {
        return 6;
    }

    function donationCount() external view returns (uint256) {
        return donationCheckpoints.length;
    }

    /// @notice Sum independent linear tranches with a binary search over cumulative checkpoints.
    /// @dev Dust cannot reset vesting or exhaust a fixed queue. Lookup cost is logarithmic.
    function unvestedDonations() public view returns (uint256) {
        uint256 count = donationCheckpoints.length;
        if (count == 0) return 0;
        uint256 low = vestingStartIndex;
        uint256 high = count;
        while (low < high) {
            uint256 mid = (low + high) / 2;
            if (uint256(donationCheckpoints[mid].start) + VESTING <= block.timestamp) low = mid + 1;
            else high = mid;
        }
        if (low == count) return 0;
        DonationCheckpoint memory last = donationCheckpoints[count - 1];
        uint256 amount = last.cumulativeAmount;
        uint256 weight = last.cumulativeUnlockWeight;
        if (low != 0) {
            DonationCheckpoint memory expired = donationCheckpoints[low - 1];
            amount -= expired.cumulativeAmount;
            weight -= expired.cumulativeUnlockWeight;
        }
        return Math.ceilDiv(weight - amount * block.timestamp, VESTING);
    }

    /// @notice Part of released auction-loss allowances not yet recognised in share value (F4).
    function unvestedRelease() public view returns (uint256) {
        uint256 amount = releaseVestingAmount;
        if (amount == 0) return 0;
        uint256 elapsed = block.timestamp - releaseVestingStart;
        if (elapsed >= VESTING) return 0;
        return Math.mulDiv(amount, VESTING - elapsed, VESTING, Math.Rounding.Ceil);
    }

    function totalAssets() public view override returns (uint256) {
        // Launch review (medium, e5e83677): the unvested release is a deferral of recognition, not an
        // asset. Idle cash it once stood behind may have been withdrawn and principal marked as lost
        // since, so it can never push the book below zero.
        uint256 recognised = _recognisedAssets();
        return recognised - Math.min(recognised, unvestedRelease());
    }

    /// @dev Cash and principal less the larger of the reserve and the expected auction loss, before the
    /// release stream. Reserve covers recognised auction impairments before any share value is lost.
    function _recognisedAssets() private view returns (uint256) {
        return IERC20(asset()).balanceOf(address(this)) + totalBorrowed
            - Math.max(shortfallReserve, expectedAuctionLoss) - unvestedDonations();
    }

    function idleAssets() public view returns (uint256) {
        return IERC20(asset()).balanceOf(address(this)) - shortfallReserve - unvestedDonations();
    }

    function maxDeposit(address) public view override returns (uint256) {
        uint256 assets = totalAssets();
        return assets >= depositCap ? 0 : depositCap - assets;
    }

    function maxMint(address receiver) public view override returns (uint256) {
        return previewDeposit(maxDeposit(receiver));
    }

    /// @dev Launch audit (medium, 0ac9b173): a released loss allowance vests to whoever holds shares, so a
    /// deposit made at the depressed price during the stream captured most of a release that belongs to
    /// the lenders who bore the loss. Entries are priced as if the release had already vested; redemptions
    /// keep the vesting price, so the unvested part can neither be bought nor withdrawn early.
    function previewDeposit(uint256 assets) public view override returns (uint256) {
        return Math.mulDiv(assets, totalSupply() + 10 ** _decimalsOffset(), _entryAssets() + 1, Math.Rounding.Floor);
    }

    function previewMint(uint256 shares) public view override returns (uint256) {
        return Math.mulDiv(shares, _entryAssets() + 1, totalSupply() + 10 ** _decimalsOffset(), Math.Rounding.Ceil);
    }

    /// @dev Launch review (medium, 548fab74): an outstanding mark is priced like an unvested release.
    /// Entries pay for cash and principal net of the reserve only, so a deposit between markOverdue
    /// and settlement cannot buy the reversal of a mark its holder never bore; it bears the mark if
    /// it is realised instead. Never below totalAssets(), so an entrant never beats a holder's price.
    function _entryAssets() private view returns (uint256) {
        return IERC20(asset()).balanceOf(address(this)) + totalBorrowed - shortfallReserve - unvestedDonations();
    }

    function maxWithdraw(address account) public view override returns (uint256) {
        return Math.min(previewRedeem(balanceOf(account)), idleAssets());
    }

    function maxRedeem(address account) public view override returns (uint256) {
        uint256 shares = balanceOf(account);
        uint256 idle = idleAssets();
        if (previewRedeem(shares) <= idle) return shares;
        // Largest share amount whose floor-rounded redemption fits the available cash.
        return Math.min(shares, previewWithdraw(idle + 1) - 1);
    }

    function deposit(uint256 assets, address receiver) public override nonReentrant returns (uint256) {
        if (assets == 0 || previewDeposit(assets) == 0) revert InvalidAmount();
        return super.deposit(assets, receiver);
    }

    function mint(uint256 shares, address receiver) public override nonReentrant returns (uint256) {
        if (shares == 0) revert InvalidAmount();
        return super.mint(shares, receiver);
    }

    function withdraw(uint256 assets, address receiver, address account)
        public
        override
        nonReentrant
        returns (uint256)
    {
        return super.withdraw(assets, receiver, account);
    }

    function redeem(uint256 shares, address receiver, address account) public override nonReentrant returns (uint256) {
        return super.redeem(shares, receiver, account);
    }

    function depositETH(address receiver) external payable nonReentrant returns (uint256 shares) {
        if (msg.value == 0) revert InvalidAmount();
        if (msg.value > maxDeposit(receiver)) revert CapExceeded();
        shares = previewDeposit(msg.value);
        if (shares == 0) revert InvalidAmount();
        IWETH(asset()).deposit{value: msg.value}();
        _mint(receiver, shares);
        emit Deposit(msg.sender, receiver, msg.value, shares);
    }

    function withdrawETH(uint256 assets, address receiver, address account)
        external
        nonReentrant
        returns (uint256 shares)
    {
        if (assets > maxWithdraw(account)) revert InsufficientIdle();
        shares = previewWithdraw(assets);
        _withdrawNative(assets, shares, receiver, account);
    }

    function redeemETH(uint256 shares, address receiver, address account)
        external
        nonReentrant
        returns (uint256 assets)
    {
        if (shares > maxRedeem(account)) revert InsufficientIdle();
        assets = previewRedeem(shares);
        _withdrawNative(assets, shares, receiver, account);
    }

    function _withdrawNative(uint256 assets, uint256 shares, address receiver, address account) private {
        if (receiver == address(0)) revert InvalidRecipient();
        if (assets == 0) revert InvalidAmount();
        if (msg.sender != account) _spendAllowance(account, msg.sender, shares);
        _burn(account, shares);
        IWETH(asset()).withdraw(assets);
        _reserveEmptyPool();
        _credit(receiver, assets);
        emit Withdraw(msg.sender, receiver, account, assets, shares);
    }

    function borrow(uint256 amount) external onlyShop nonReentrant {
        if (amount > idleAssets()) revert InsufficientIdle();
        totalBorrowed += amount;
        IWETH(asset()).withdraw(amount);
        (bool ok,) = pawnShop.call{value: amount}("");
        if (!ok) revert ETHTransferFailed();
        emit Borrowed(amount);
    }

    /// @notice On auction loss the reserve changes classification, making it available to shares.
    function settle(uint256 principal) external payable onlyShop nonReentrant {
        _settle(principal);
    }

    /// @notice Only the shop can recognise a loan's expected loss. It never decreases unless the shop
    /// reports that the collateral is still held (`mayDecrease`), for example after a fresh-floor restart.
    function markAuctionLoss(uint256 id, uint256 principal, uint256 recovery, bool mayDecrease) external onlyShop {
        if (principal > totalBorrowed) revert InvalidAmount();
        uint256 loss = principal - Math.min(principal, recovery);
        uint256 previous = auctionLoss[id];
        if (loss < previous && !mayDecrease) revert InvalidAmount();
        uint256 before = _recognisedAssets();
        expectedAuctionLoss = expectedAuctionLoss + loss - previous;
        auctionLoss[id] = loss;
        // Launch review (high, b79122ba): a lowered mark is the same kind of release as a settlement
        // and vests the same way; a raised mark first cancels what is still unvested.
        _reconcileRelease(id, before);
        emit AuctionLossMarked(id, loss);
    }

    function settleAuction(uint256 id, uint256 principal) external payable onlyShop nonReentrant {
        uint256 before = _recognisedAssets();
        expectedAuctionLoss -= auctionLoss[id];
        delete auctionLoss[id];
        reserveUsed[id] += _settle(principal);
        // F4: an allowance larger than the realised loss is recognised over seven days, not at once.
        _reconcileRelease(id, before);
    }

    /// @dev Stream any rise of the recognised book since `before` over VESTING; absorb any fall into
    /// the unvested remainder first so a loss re-marked after a release is not deducted twice.
    function _reconcileRelease(uint256 id, uint256 before) private {
        uint256 afterChange = _recognisedAssets();
        if (afterChange > before) {
            if (totalSupply() == 0) return;
            uint256 remaining = unvestedRelease();
            releaseVestingAmount = remaining + afterChange - before;
            releaseVestingStart = block.timestamp;
            emit AllowanceReleaseVesting(id, afterChange - before, releaseVestingAmount);
        } else if (afterChange < before) {
            uint256 remaining = unvestedRelease();
            if (remaining == 0) return;
            uint256 cancelled = Math.min(remaining, before - afterChange);
            releaseVestingAmount = remaining - cancelled;
            releaseVestingStart = block.timestamp;
            emit AllowanceReleaseCancelled(id, cancelled, releaseVestingAmount);
        }
    }

    function _settle(uint256 principal) private returns (uint256 covered) {
        if (msg.value > principal || principal > totalBorrowed) revert InvalidAmount();
        uint256 gap = principal - msg.value;
        covered = Math.min(gap, shortfallReserve);
        shortfallReserve -= covered;
        totalBorrowed -= principal;
        cumulativeLoss += gap - covered;
        if (msg.value != 0) IWETH(asset()).deposit{value: msg.value}();
        _reserveEmptyPool();
        emit Settled(principal, msg.value, covered, gap - covered);
    }

    function receiveFee() external payable onlyShop nonReentrant {
        cumulativeLoanFees += msg.value;
        _receiveIncome();
        emit FeeReceived(msg.value);
    }

    /// @notice Late recoveries of written-off loans first restore the reserve that loan consumed (F9);
    /// the rest accrues to current lenders over seven days.
    function receiveRecovery(uint256 id) external payable onlyShop nonReentrant {
        cumulativeRecoveries += msg.value;
        uint256 restore = Math.min(msg.value, reserveUsed[id]);
        if (restore != 0) {
            reserveUsed[id] -= restore;
            shortfallReserve += restore;
            emit ReserveRestored(id, restore);
        }
        _receiveIncome(msg.value - restore);
        emit RecoveryReceived(msg.value);
    }

    function _receiveIncome() private {
        _receiveIncome(msg.value);
    }

    /// @dev Wraps all of msg.value; only `income` is treated as lender income.
    function _receiveIncome(uint256 income) private {
        if (msg.value == 0) return;
        IWETH(asset()).deposit{value: msg.value}();
        if (income == 0) return;
        if (totalSupply() == 0) {
            shortfallReserve += income;
            emit ReserveAdded(income);
        } else {
            _vest(income);
        }
    }

    function addReserve() external payable onlyShop nonReentrant {
        shortfallReserve += msg.value;
        IWETH(asset()).deposit{value: msg.value}();
        emit ReserveAdded(msg.value);
    }

    function donate() external payable nonReentrant {
        if (totalSupply() == 0 || msg.value == 0) revert InvalidAmount();
        _vest(msg.value);
        cumulativeDonations += msg.value;
        IWETH(asset()).deposit{value: msg.value}();
        emit Donated(msg.sender, msg.value, donationCheckpoints.length - 1);
    }

    function _vest(uint256 value) private {
        if (value > type(uint128).max || block.timestamp > type(uint64).max) {
            revert InvalidAmount();
        }
        uint256 count = donationCheckpoints.length;
        uint256 amount = value;
        uint256 weight = value * (block.timestamp + VESTING);
        if (count != 0) {
            DonationCheckpoint storage last = donationCheckpoints[count - 1];
            amount += last.cumulativeAmount;
            weight += last.cumulativeUnlockWeight;
            if (last.start == block.timestamp && count > vestingStartIndex) {
                last.cumulativeAmount = amount;
                last.cumulativeUnlockWeight = weight;
            } else {
                donationCheckpoints.push(DonationCheckpoint(uint64(block.timestamp), amount, weight));
            }
        } else {
            donationCheckpoints.push(DonationCheckpoint(uint64(block.timestamp), amount, weight));
        }
    }

    function _withdraw(address caller, address receiver, address account, uint256 assets, uint256 shares)
        internal
        override
    {
        super._withdraw(caller, receiver, account, assets, shares);
        _reserveEmptyPool();
    }

    /// @dev Retire leftover streams and rounding dust when the last actual share is burned.
    function _reserveEmptyPool() private {
        if (totalSupply() != 0) return;
        uint256 cash = IERC20(asset()).balanceOf(address(this));
        uint256 amount = cash - shortfallReserve;
        shortfallReserve = cash;
        vestingStartIndex = donationCheckpoints.length;
        delete releaseVestingAmount;
        delete releaseVestingStart;
        if (amount != 0) emit EmptyPoolReserve(amount);
    }

    function queueDepositCap(uint256 cap) external onlyOwner {
        if (cap <= depositCap) revert InvalidAmount();
        pendingCap = cap;
        pendingCapAt = block.timestamp + DELAY;
        emit CapQueued(cap, pendingCapAt);
    }

    function executeDepositCap() external {
        if (pendingCapAt == 0 || block.timestamp < pendingCapAt) revert TimelockPending();
        if (block.timestamp > pendingCapAt + EXECUTION_WINDOW) revert WindowExpired();
        depositCap = pendingCap;
        delete pendingCap;
        delete pendingCapAt;
        emit CapRaised(depositCap);
    }

    function cancelDepositCap() external onlyOwner {
        if (pendingCapAt == 0) revert TimelockPending();
        emit CapCancelled(pendingCap);
        delete pendingCap;
        delete pendingCapAt;
    }

    receive() external payable {
        if (msg.sender != asset()) revert DirectETHDisabled();
    }
}
