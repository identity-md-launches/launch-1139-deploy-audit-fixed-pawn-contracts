// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {OracleAttestation, OracleAttestationConsumer} from "./OracleAttestation.sol";
import {PullPayments} from "./PullPayments.sol";
import {LendingPool} from "./LendingPool.sol";
import {LockDiscount} from "./LockDiscount.sol";
import {CollateralVault} from "./CollateralVault.sol";
import {VaultFactory} from "./VaultFactory.sol";
import {IDiscountModule} from "./interfaces/IPawn.sol";

/// @notice Fixed principal, no mark-to-market liquidation, permissionless expiry auctions.
contract PawnShop is Ownable2Step, PullPayments, OracleAttestationConsumer {
    error Paused();
    error InvalidConfiguration();
    error NotConfigured();
    error TimelockPending();
    error CollectionDisabled();
    error InvalidTerm();
    error StaleFloor();
    error InvalidAttestation();
    error LoanTooSmall();
    error ShareExceeded();
    error InvalidLoan();
    error Unauthorized();
    error IncorrectPayment();
    error GracePeriod();
    error NotAuctioning();
    error RenounceDisabled();
    error Slippage();
    error SameBlock();
    error CollateralMissing();
    error NotRestartable();
    error NotOverdue();
    error QuestionCooldown();

    address public constant IDENTITY_COLLECTION = 0x0000eC93127BAA929E58E97dd0095A2BFb38ec1D;
    uint256 public constant DELAY = 48 hours;
    uint256 public constant EXECUTION_WINDOW = 7 days;
    uint256 public constant WRITE_OFF_DELAY = 40 days;
    uint256 public constant FLOOR_MAX_AGE = 26 hours;
    uint256 public constant FLOOR_BOUNTY_INTERVAL = 24 hours;
    uint256 public constant GRACE = 3 days;
    uint256 public constant MIN_LOAN = 0.01 ether;
    uint256 public constant BOUNTY_TARGET = 0.2 ether;
    uint256 public constant FLOOR_BOUNTY = 0.001 ether;
    uint256 public constant AUCTION_BOUNTY = 0.002 ether;
    /// @dev Audit F2: an auction may restart once it has sat at its terminal price (reached at 10 days) for 7 days.
    uint256 public constant RESTART_AFTER = 17 days;
    /// @dev Audit F15: new loans stay disabled this long after any question hash write.
    uint256 public constant QUESTION_COOLDOWN = 48 hours;
    /// @dev Audit F8: attested block windows must close within roughly 26 hours of blocks.
    uint256 public constant MAX_WINDOW_AGE_BLOCKS = 7800;
    /// @notice Constructor preset for the identity.md collection's floor question (exempt from F15).
    bytes32 public constant IDENTITY_QUESTION_HASH = 0x71ed43868c5c61fe21b72bbbdcc09913d4952a113a393c526e49f3289edf4be1;

    LendingPool public immutable lendingPool;
    VaultFactory public immutable vaultFactory;
    address public immutable pawnToken;
    address public discountModule;
    address public feeRecipient;
    bool public newLoansPaused = true;
    uint256 public nextLoanId = 1;
    uint256 public bountyReserve;
    /// @notice Cumulative protocol fees credited to the fee recipient(s).
    uint256 public protocolFeesToRecipient;
    /// @notice Cumulative protocol fees moved into the bounty and shortfall reserves.
    uint256 public protocolFeesToReserves;

    struct Term {
        uint32 duration;
        uint16 feeBps;
    }
    Term[2] public terms;

    struct Collection {
        uint16 maxLoanBps0;
        uint16 maxLoanBps1;
        uint16 maxShareBps;
        bool isSeat;
        bool enabled;
        bytes32 questionHash;
    }

    struct Floor {
        uint256 price;
        uint64 issuedAt;
        uint64 expiresAt;
        uint64 lastBountyAt;
    }
    enum Status {
        None,
        Active,
        Auction,
        Repaid,
        Sold
    }

    struct Loan {
        address borrower;
        address collection;
        address vault;
        address module;
        uint256 tokenId;
        uint256 principal;
        uint256 due;
        uint256 auctionStarted;
        uint256 auctionFloor;
        Status status;
        Term[2] savedTerms;
    }
    mapping(address => Collection) public collections;
    mapping(address => Floor) public floors;
    mapping(address => uint256) public collectionDebt;
    mapping(uint256 => Loan) private _loans;
    mapping(bytes32 => uint256) public queuedAt;
    mapping(bytes32 => bytes32) public latestChange;
    mapping(uint256 => bool) public writtenOff;
    /// @notice New loans against a collection are refused until this time (audit F15).
    mapping(address => uint256) public loansDisabledUntil;
    /// @notice Launch audit (high, da7976ab): the oracle's questionHash covers the request's block window, so
    /// every fresh floor request carries a new hash and the timelocked pin alone can never admit a live
    /// price. The owner may admit one request's hash immediately, on top of the governed pin. Cleared when
    /// the governed question rotates.
    mapping(address => bytes32) public approvedQuestionHash;

    event PauseChanged(bool paused);
    event ChangeQueued(bytes32 indexed operation, uint256 executableAt);
    event ChangeCancelled(bytes32 indexed operation);
    event TermSet(uint8 indexed termId, uint32 duration, uint16 feeBps);
    event CollectionSet(address indexed collection, Collection config);
    event CollectionDisabledNow(address indexed collection);
    event QuestionHashSet(address indexed collection, bytes32 questionHash);
    event QuestionHashApproved(address indexed collection, bytes32 questionHash);
    event FeeRecipientSet(address indexed recipient);
    event DiscountModuleSet(address indexed module);
    event FloorSubmitted(address indexed collection, uint256 price, uint64 issuedAt, uint64 expiresAt);
    event Pawned(
        uint256 indexed loanId,
        address indexed borrower,
        address indexed collection,
        uint256 tokenId,
        address vault,
        uint256 principal,
        uint256 fee,
        uint256 due
    );
    event Repaid(uint256 indexed loanId);
    event Extended(uint256 indexed loanId, uint8 termId, uint256 fee, uint256 due);
    event AuctionStarted(uint256 indexed loanId, uint256 floor, uint256 timestamp);
    event AuctionBought(uint256 indexed loanId, address indexed buyer, address indexed receiver, uint256 price);
    event BountyFunded(address indexed sender, uint256 amount);
    event AuctionWrittenOff(uint256 indexed loanId, uint256 principal);
    event AuctionRestarted(uint256 indexed loanId, uint256 floor, uint256 timestamp);
    event LoanMarkedOverdue(uint256 indexed loanId, uint256 expectedLoss);
    event DiscountReleaseFailed(uint256 indexed loanId, address indexed module);
    event ProtocolFeeSplit(uint256 toRecipient, uint256 toBountyReserve, uint256 toShortfallReserve);

    /// @dev Child contracts bind this shop in their constructors, avoiding circular manifest references.
    constructor(address owner_, address token_, address weth_, address attester_)
        Ownable(owner_)
        OracleAttestationConsumer(attester_)
    {
        if (token_ == address(0) || weth_ == address(0)) revert InvalidConfiguration();
        pawnToken = token_;
        feeRecipient = owner_;
        lendingPool = new LendingPool(owner_, weth_, address(this));
        vaultFactory = new VaultFactory();
        discountModule = address(new LockDiscount(token_, address(this)));
        terms[0] = Term(30 days, 300);
        terms[1] = Term(7 days, 100);
        collections[IDENTITY_COLLECTION] = Collection(4000, 4000, 10000, true, true, IDENTITY_QUESTION_HASH);
    }

    function renounceOwnership() public view override onlyOwner {
        revert RenounceDisabled();
    }

    function getLoan(uint256 id) external view returns (Loan memory) {
        return _loans[id];
    }

    function loanActive(uint256 id) external view returns (bool) {
        return _loans[id].status == Status.Active;
    }

    function setNewLoansPaused(bool paused_) external onlyOwner {
        newLoansPaused = paused_;
        emit PauseChanged(paused_);
    }

    function _queue(bytes32 kind, bytes32 op) private {
        bytes32 previous = latestChange[kind];
        if (queuedAt[previous] != 0) {
            delete queuedAt[previous];
            emit ChangeCancelled(previous);
        }
        latestChange[kind] = op;
        queuedAt[op] = block.timestamp + DELAY;
        emit ChangeQueued(op, queuedAt[op]);
    }

    function _execute(bytes32 op) private {
        if (queuedAt[op] == 0 || block.timestamp < queuedAt[op] || block.timestamp > queuedAt[op] + EXECUTION_WINDOW) {
            revert TimelockPending();
        }
        delete queuedAt[op];
    }

    function cancelChange(bytes32 op) external onlyOwner {
        delete queuedAt[op];
        emit ChangeCancelled(op);
    }

    function queueTerm(uint8 id, uint32 duration, uint16 feeBps) external onlyOwner {
        _validateTerm(id, duration, feeBps);
        _queue(keccak256(abi.encode("term", id)), keccak256(abi.encode("term", id, duration, feeBps)));
    }

    function executeTerm(uint8 id, uint32 duration, uint16 feeBps) external {
        _execute(keccak256(abi.encode("term", id, duration, feeBps)));
        terms[id] = Term(duration, feeBps);
        emit TermSet(id, duration, feeBps);
    }

    function _validateTerm(uint8 id, uint32 duration, uint16 feeBps) private pure {
        if (id > 1 || duration < 7 days || duration > 90 days || feeBps < 50 || feeBps > 1000) revert InvalidTerm();
    }

    function queueCollection(address collection, Collection calldata config) external onlyOwner {
        if (
            collection == address(0) || config.maxLoanBps0 > 4000 || config.maxLoanBps1 > 4000
                || config.maxShareBps > 10000 || (!config.isSeat && config.maxShareBps > 2500)
        ) revert InvalidConfiguration();
        // A configured hash may rotate only to a real, timelocked hash, never back to the one-shot path.
        if (collections[collection].questionHash != bytes32(0) && config.questionHash == bytes32(0)) {
            revert InvalidConfiguration();
        }
        _queue(keccak256(abi.encode("collection", collection)), keccak256(abi.encode("collection", collection, config)));
    }

    function executeCollection(address collection, Collection calldata config) external {
        _execute(keccak256(abi.encode("collection", collection, config)));
        if (
            collection.code.length == 0
                || (collections[collection].questionHash != bytes32(0) && config.questionHash == bytes32(0))
        ) revert InvalidConfiguration();
        if (collections[collection].questionHash != config.questionHash) {
            // Keep the last price for default auctions, but require a newly signed floor for lending.
            floors[collection].expiresAt = 0;
            loansDisabledUntil[collection] = block.timestamp + QUESTION_COOLDOWN;
            delete approvedQuestionHash[collection];
        }
        collections[collection] = config;
        emit CollectionSet(collection, config);
    }

    function disableCollection(address collection) external onlyOwner {
        bytes32 op = latestChange[keccak256(abi.encode("collection", collection))];
        if (queuedAt[op] != 0) {
            delete queuedAt[op];
            emit ChangeCancelled(op);
        }
        collections[collection].enabled = false;
        emit CollectionDisabledNow(collection);
    }

    function setQuestionHashOnce(address collection, bytes32 hash) external onlyOwner {
        Collection storage c = collections[collection];
        if (c.maxShareBps == 0 || c.questionHash != bytes32(0) || hash == bytes32(0)) revert InvalidConfiguration();
        c.questionHash = hash;
        loansDisabledUntil[collection] = block.timestamp + QUESTION_COOLDOWN;
        emit QuestionHashSet(collection, hash);
    }

    /// @notice Admit the hash of one specific floor request for a collection whose question is already
    /// governed. The owner vouches that the request asks the configured question; the governed pin and
    /// its timelock are untouched, and every other submitFloor rule (consensus, age, window, signature,
    /// single use of the request id) still applies to the admitted answer.
    function approveQuestionHash(address collection, bytes32 hash) external onlyOwner {
        if (collections[collection].questionHash == bytes32(0) || hash == bytes32(0)) revert InvalidConfiguration();
        approvedQuestionHash[collection] = hash;
        emit QuestionHashApproved(collection, hash);
    }

    function queueAttester(address signer) external onlyOwner {
        if (signer == address(0)) revert InvalidConfiguration();
        _queue(keccak256("attester"), keccak256(abi.encode("attester", signer)));
    }

    function executeAttester(address signer) external {
        _execute(keccak256(abi.encode("attester", signer)));
        _setOracleSigner(signer);
    }

    function queueFeeRecipient(address recipient) external onlyOwner {
        if (recipient == address(0)) revert InvalidConfiguration();
        _queue(keccak256("recipient"), keccak256(abi.encode("recipient", recipient)));
    }

    function executeFeeRecipient(address recipient) external {
        _execute(keccak256(abi.encode("recipient", recipient)));
        feeRecipient = recipient;
        emit FeeRecipientSet(recipient);
    }

    function queueDiscountModule(address module) external onlyOwner {
        _validateModule(module);
        _queue(keccak256("module"), keccak256(abi.encode("module", module)));
    }

    function executeDiscountModule(address module) external {
        _execute(keccak256(abi.encode("module", module)));
        _validateModule(module);
        discountModule = module;
        emit DiscountModuleSet(module);
    }

    function _validateModule(address module) private view {
        if (
            module.code.length == 0 || IDiscountModule(module).pawnShop() != address(this)
                || IDiscountModule(module).pawnToken() != pawnToken
        ) revert InvalidConfiguration();
    }

    function submitFloor(address collection, OracleAttestation.Attestation calldata a, bytes calldata signature)
        external
        nonReentrant
    {
        bytes32 hash = collections[collection].questionHash;
        if (hash == bytes32(0)) revert NotConfigured();
        if (
            (a.questionHash != hash && a.questionHash != approvedQuestionHash[collection]) || a.chainId != 1
                || a.panelSize < 5 || a.quorum < 4 || a.agreed < a.quorum || a.agreed > a.panelSize
                || a.issuedAt > block.timestamp || block.timestamp - a.issuedAt > FLOOR_MAX_AGE
                || a.issuedAt <= floors[collection].issuedAt || a.fromBlock > a.toBlock
                || uint256(a.toBlock) + MAX_WINDOW_AGE_BLOCKS < block.number
        ) revert InvalidAttestation();
        _verifyAttestation(a, signature);
        uint256 price = decodeUint256(a);
        if (price == 0 || a.answer.length != 32) revert InvalidAttestation();
        // Launch audit (low, 56506f8c): the service issues floors with a 24-hour validity, so the former
        // 26-hour minimum lifetime refused every real answer. floorFresh already bounds freshness by
        // min(FLOOR_MAX_AGE, signed expiry); a signed expiry is never extended.
        if (a.expiresAt <= a.issuedAt) revert InvalidAttestation();
        _consume(a.requestId);
        Floor storage f = floors[collection];
        f.price = price;
        f.issuedAt = a.issuedAt;
        f.expiresAt = a.expiresAt;
        // The first valid update consumes the interval even if its reserve was empty.
        if (f.lastBountyAt == 0 || block.timestamp >= uint256(f.lastBountyAt) + FLOOR_BOUNTY_INTERVAL) {
            f.lastBountyAt = uint64(block.timestamp);
            _payBounty(msg.sender, FLOOR_BOUNTY);
        }
        emit FloorSubmitted(collection, price, a.issuedAt, a.expiresAt);
    }

    function floorFresh(address collection) public view returns (bool) {
        Floor memory f = floors[collection];
        return f.price != 0 && f.issuedAt <= block.timestamp && block.timestamp - f.issuedAt <= FLOOR_MAX_AGE
            && block.timestamp <= f.expiresAt;
    }

    /// @param minPrincipal Smallest principal the borrower accepts (audit F6).
    /// @param maxFee Largest upfront fee the borrower accepts (audit F6).
    function pawn(address collection, uint256 tokenId, uint8 termId, uint256 minPrincipal, uint256 maxFee)
        external
        nonReentrant
        returns (uint256 id)
    {
        if (newLoansPaused) revert Paused();
        if (block.timestamp < loansDisabledUntil[collection]) revert QuestionCooldown();
        if (termId > 1) revert InvalidTerm();
        Collection memory c = collections[collection];
        uint256 ltv = termId == 0 ? c.maxLoanBps0 : c.maxLoanBps1;
        if (!c.enabled || ltv == 0) revert CollectionDisabled();
        if (!floorFresh(collection)) revert StaleFloor();
        uint256 principal = Math.mulDiv(floors[collection].price, ltv, 10000);
        if (principal < MIN_LOAN) revert LoanTooSmall();
        if (principal < minPrincipal) revert Slippage();
        if (collectionDebt[collection] + principal > Math.mulDiv(lendingPool.totalAssets(), c.maxShareBps, 10000)) {
            revert ShareExceeded();
        }

        id = nextLoanId++;
        CollateralVault vault = CollateralVault(payable(vaultFactory.create()));
        Loan storage loan = _loans[id];
        loan.borrower = msg.sender;
        loan.collection = collection;
        loan.vault = address(vault);
        loan.module = discountModule;
        loan.tokenId = tokenId;
        loan.principal = principal;
        loan.due = block.timestamp + terms[termId].duration;
        loan.status = Status.Active;
        loan.savedTerms[0] = terms[0];
        loan.savedTerms[1] = terms[1];
        collectionDebt[collection] += principal;

        uint256 fee = _commitFee(id, loan, termId);
        if (fee > maxFee) revert Slippage();
        vault.initialize(msg.sender, collection, tokenId, id, address(lendingPool), c.isSeat);
        IERC721(collection).safeTransferFrom(msg.sender, address(vault), tokenId);
        if (IERC721(collection).ownerOf(tokenId) != address(vault)) revert InvalidLoan();
        lendingPool.borrow(principal);
        _credit(msg.sender, principal - fee);
        _distributeFee(fee);
        emit Pawned(id, msg.sender, collection, tokenId, address(vault), principal, fee, loan.due);
    }

    function repay(uint256 id) external payable nonReentrant {
        Loan storage loan = _active(id);
        if (msg.value != loan.principal) revert IncorrectPayment();
        loan.status = Status.Repaid;
        collectionDebt[loan.collection] -= loan.principal;
        // An overdue mark (F5) is cleared through the auction settlement path.
        if (lendingPool.auctionLoss(id) != 0) lendingPool.settleAuction{value: msg.value}(id, loan.principal);
        else lendingPool.settle{value: msg.value}(loan.principal);
        _releaseDiscount(id, loan.module);
        CollateralVault(payable(loan.vault)).release(loan.borrower);
        emit Repaid(id);
    }

    function extend(uint256 id, uint8 termId) external payable nonReentrant {
        Loan storage loan = _active(id);
        if (msg.sender != loan.borrower) revert Unauthorized();
        if (termId > 1) revert InvalidTerm();
        if (!floorFresh(loan.collection)) revert StaleFloor();
        uint256 fee = _commitFee(id, loan, termId);
        if (msg.value != fee) revert IncorrectPayment();
        // Late extensions buy a complete new term; early extensions append to the existing due date.
        loan.due = Math.max(loan.due, block.timestamp) + loan.savedTerms[termId].duration;
        _distributeFee(fee);
        emit Extended(id, termId, fee, loan.due);
    }

    function _commitFee(uint256 id, Loan storage loan, uint8 termId) private returns (uint256) {
        uint256 base = Math.mulDiv(loan.principal, loan.savedTerms[termId].feeBps, 10000, Math.Rounding.Ceil);
        return Math.min(base, IDiscountModule(loan.module).commit(id, loan.borrower, base));
    }

    function _active(uint256 id) private view returns (Loan storage loan) {
        loan = _loans[id];
        if (loan.status != Status.Active) revert InvalidLoan();
    }

    /// @dev Audit F16: a misbehaving discount module can never block settlement.
    function _releaseDiscount(uint256 id, address module) private {
        try IDiscountModule(module).release(id) {}
        catch {
            emit DiscountReleaseFailed(id, module);
        }
    }

    /// @notice From the due date onward, anyone may book the expected loss against half the stored floor (F5).
    function markOverdue(uint256 id) external nonReentrant {
        Loan storage loan = _active(id);
        if (block.timestamp < loan.due) revert NotOverdue();
        uint256 recovery = Math.min(loan.principal, floors[loan.collection].price / 2);
        lendingPool.markAuctionLoss(id, loan.principal, recovery, false);
        emit LoanMarkedOverdue(id, lendingPool.auctionLoss(id));
    }

    function startAuction(uint256 id) external nonReentrant {
        Loan storage loan = _active(id);
        if (block.timestamp <= loan.due + GRACE) revert GracePeriod();
        if (!floorFresh(loan.collection)) revert StaleFloor();
        loan.status = Status.Auction;
        loan.auctionStarted = block.timestamp;
        loan.auctionFloor = floors[loan.collection].price;
        lendingPool.markAuctionLoss(
            id, loan.principal, auctionPrice(id), CollateralVault(payable(loan.vault)).holdsCollateral()
        );
        // Audit F7: the borrower earns no bounty for auctioning their own loan; small loans pay at most 1%.
        if (msg.sender != loan.borrower) _payBounty(msg.sender, Math.min(AUCTION_BOUNTY, loan.principal / 100));
        emit AuctionStarted(id, loan.auctionFloor, block.timestamp);
    }

    /// @notice Re-run the price curve from a fresh floor after a write-off or 7 days at the terminal price (F2).
    function restartAuction(uint256 id) external nonReentrant {
        Loan storage loan = _loans[id];
        if (loan.status != Status.Auction) revert NotAuctioning();
        // Launch audit (medium, bf57e268): written-off auctions also wait RESTART_AFTER between restarts, so a
        // free restart in every block can no longer reset the price curve and block every purchase.
        if (block.timestamp < loan.auctionStarted + RESTART_AFTER) revert NotRestartable();
        if (!floorFresh(loan.collection)) revert StaleFloor();
        loan.auctionStarted = block.timestamp;
        loan.auctionFloor = floors[loan.collection].price;
        if (!writtenOff[id]) {
            lendingPool.markAuctionLoss(
                id, loan.principal, auctionPrice(id), CollateralVault(payable(loan.vault)).holdsCollateral()
            );
        }
        emit AuctionRestarted(id, loan.auctionFloor, block.timestamp);
    }

    function auctionPrice(uint256 id) public view returns (uint256) {
        Loan storage loan = _loans[id];
        if (loan.status != Status.Auction) revert NotAuctioning();
        if (!CollateralVault(payable(loan.vault)).holdsCollateral()) return 0;
        uint256 elapsed = block.timestamp - loan.auctionStarted;
        uint256 floor = loan.auctionFloor;
        // Continuous rational slopes, rounding the final price up in favor of the pool.
        if (elapsed <= 3 days) {
            return Math.mulDiv(floor, 10000 * 3 days - 3000 * elapsed, 10000 * 3 days, Math.Rounding.Ceil);
        }
        if (elapsed < 10 days) {
            return Math.mulDiv(floor, 7000 * 7 days - 2000 * (elapsed - 3 days), 10000 * 7 days, Math.Rounding.Ceil);
        }
        return Math.mulDiv(floor, 5000, 10000, Math.Rounding.Ceil);
    }

    /// @notice Refresh the loss allowance as an auction declines; never releases custody.
    function markAuctionLoss(uint256 id) external nonReentrant {
        uint256 price = auctionPrice(id);
        if (writtenOff[id]) revert InvalidLoan();
        Loan storage loan = _loans[id];
        lendingPool.markAuctionLoss(id, loan.principal, price, CollateralVault(payable(loan.vault)).holdsCollateral());
    }

    /// @notice After 30 days at the terminal price, remove unrecovered debt and unlock PAWN.
    /// Collateral stays in its auction; a later buyer still pays the original auction curve.
    function writeOffAuction(uint256 id) external nonReentrant {
        Loan storage loan = _loans[id];
        if (loan.status != Status.Auction || writtenOff[id]) revert InvalidLoan();
        if (
            block.timestamp < loan.auctionStarted + WRITE_OFF_DELAY
                && CollateralVault(payable(loan.vault)).holdsCollateral()
        ) revert GracePeriod();
        writtenOff[id] = true;
        collectionDebt[loan.collection] -= loan.principal;
        lendingPool.settleAuction(id, loan.principal);
        _releaseDiscount(id, loan.module);
        emit AuctionWrittenOff(id, loan.principal);
    }

    /// @notice msg.value is a price ceiling; any excess becomes the buyer's pull credit.
    function buyAuction(uint256 id, address receiver) external payable nonReentrant {
        Loan storage loan = _loans[id];
        if (receiver == address(0) || receiver == loan.vault || receiver == loan.collection) {
            revert InvalidRecipient();
        }
        uint256 price = auctionPrice(id);
        // Audit F1: no purchase in the block that started (or restarted) the auction.
        if (block.timestamp == loan.auctionStarted) revert SameBlock();
        // Audit F3: no zero-price sale of missing collateral; writeOffAuction settles that case.
        if (!CollateralVault(payable(loan.vault)).holdsCollateral()) revert CollateralMissing();
        if (msg.value < price) revert IncorrectPayment();
        loan.status = Status.Sold;
        uint256 recovered = Math.min(price, loan.principal);
        if (writtenOff[id]) {
            lendingPool.receiveRecovery{value: recovered}(id);
        } else {
            collectionDebt[loan.collection] -= loan.principal;
            lendingPool.settleAuction{value: recovered}(id, loan.principal);
            _releaseDiscount(id, loan.module);
        }
        _credit(loan.borrower, price - recovered);
        _credit(msg.sender, msg.value - price);
        CollateralVault(payable(loan.vault)).release(receiver);
        emit AuctionBought(id, msg.sender, receiver, price);
    }

    /// @dev Lenders keep 85%. While either reserve is below target, half of the 15% protocol share
    /// fills the reserves (bounty first) and half goes to the fee recipient; at target, all of it does.
    function _distributeFee(uint256 fee) private {
        uint256 protocol = Math.mulDiv(fee, 1500, 10000);
        lendingPool.receiveFee{value: fee - protocol}();
        uint256 bountyGap = BOUNTY_TARGET > bountyReserve ? BOUNTY_TARGET - bountyReserve : 0;
        uint256 target = Math.mulDiv(lendingPool.totalAssets(), 500, 10000);
        uint256 reserve = lendingPool.shortfallReserve();
        uint256 reserveGap = target > reserve ? target - reserve : 0;
        uint256 budget = bountyGap != 0 || reserveGap != 0 ? protocol / 2 : 0;
        uint256 forBounty = Math.min(budget, bountyGap);
        uint256 forReserve = Math.min(budget - forBounty, reserveGap);
        bountyReserve += forBounty;
        if (forReserve != 0) lendingPool.addReserve{value: forReserve}();
        uint256 toRecipient = protocol - forBounty - forReserve;
        protocolFeesToReserves += forBounty + forReserve;
        protocolFeesToRecipient += toRecipient;
        _credit(feeRecipient, toRecipient);
        emit ProtocolFeeSplit(toRecipient, forBounty, forReserve);
    }

    function _payBounty(address recipient, uint256 amount) private {
        // Reserve exhaustion must never stop price updates or default resolution.
        if (bountyReserve < amount) return;
        bountyReserve -= amount;
        _credit(recipient, amount);
    }

    function fundBounties() external payable nonReentrant {
        bountyReserve += msg.value;
        emit BountyFunded(msg.sender, msg.value);
    }

    receive() external payable {
        if (msg.sender != address(lendingPool)) revert Unauthorized();
    }
}
