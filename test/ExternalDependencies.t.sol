// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {PawnTestBase} from "./helpers/PawnTestBase.sol";
import {MockNFT} from "./helpers/Mocks.sol";
import {LaunchToken} from "../src/LaunchToken.sol";
import {PawnShop} from "../src/PawnShop.sol";
import {LendingPool} from "../src/LendingPool.sol";
import {LockDiscount} from "../src/LockDiscount.sol";

/// @dev Reproduces the one WETH9 behaviour the shared MockWETH does not: `withdraw` pays the caller with
/// `transfer`, which forwards only the 2300-gas stipend. LendingPool's `receive` must fit in it, or every
/// borrow, native withdrawal and redemption on mainnet reverts.
contract StipendWETH is ERC20 {
    constructor() ERC20("Wrapped Ether", "WETH") {}

    function deposit() external payable {
        _mint(msg.sender, msg.value);
    }

    function withdraw(uint256 wad) external {
        _burn(msg.sender, wad);
        payable(msg.sender).transfer(wad);
    }
}

/// @notice Offline stand-ins for the mainnet dependencies: WETH9's gas stipend and a collection that stops
/// transfers. The live checks still owed are listed in the final summary of this contribution.
contract ExternalDependenciesTest is PawnTestBase {
    StipendWETH internal weth9;

    function setUp() public override {
        vm.chainId(1);
        vm.warp(1_800_000_000);
        vm.deal(address(this), 1000 ether);
        vm.deal(alice, 100 ether);
        vm.deal(bob, 100 ether);
        vm.deal(buyer, 100 ether);
        token = new LaunchToken();
        weth9 = new StipendWETH();
        shop = new PawnShop(owner, address(token), address(weth9), vm.addr(KEY));
        pool = shop.lendingPool();
        discount = LockDiscount(shop.discountModule());
        MockNFT template = new MockNFT();
        vm.etch(shop.IDENTITY_COLLECTION(), address(template).code);
        nft = MockNFT(shop.IDENTITY_COLLECTION());
        _floor(1 ether);
        vm.prank(owner);
        shop.setNewLoansPaused(false);
        vm.prank(bob);
        pool.depositETH{value: 5 ether}(bob);
    }

    function test_poolReceiveFitsInTheWeth9TransferStipend() public {
        assertEq(weth9.balanceOf(address(pool)), 5 ether);
        // Exactly what WETH9's `transfer` forwards: no gas of its own, only the 2300 call stipend.
        vm.deal(address(weth9), address(weth9).balance + 1);
        vm.prank(address(weth9));
        (bool ok,) = address(pool).call{value: 1, gas: 0}("");
        assertTrue(ok, "receive() exceeds the 2300-gas stipend");
        // Anyone else is refused even with unlimited gas, so ETH cannot be forced into the pool.
        (ok,) = address(pool).call{value: 1}("");
        assertFalse(ok);
        (bool okShop, bytes memory reason) = address(shop).call{value: 1}("");
        assertFalse(okShop);
        assertEq(bytes4(reason), PawnShop.Unauthorized.selector);
    }

    function test_borrowWithdrawRedeemAndSettleRunThroughWeth9Semantics() public {
        // Native withdrawal: pool -> WETH9.withdraw -> transfer(2300 gas) -> pool.receive -> pull credit.
        vm.prank(bob);
        uint256 shares = pool.withdrawETH(1 ether, bob, bob);
        assertGt(shares, 0);
        assertEq(pool.claimable(bob), 1 ether);
        uint256 bobBefore = bob.balance;
        vm.prank(bob);
        pool.claim(payable(bob));
        assertEq(bob.balance - bobBefore, 1 ether);

        // Borrow: pool unwraps with the same stipend and forwards the principal to the shop.
        uint256 id = _pawn(1, 0);
        assertEq(pool.totalBorrowed(), 0.4 ether);
        assertEq(shop.claimable(alice), 0.4 ether - 0.012 ether);
        assertEq(address(pool).balance, 0, "no ETH may rest in the pool");

        // Redemption of a share amount, third path through the stipend.
        uint256 half = pool.balanceOf(bob) / 2;
        vm.prank(bob);
        uint256 assets = pool.redeemETH(half, bob, bob);
        assertGt(assets, 0);
        assertEq(pool.claimable(bob), assets);

        // Settlement wraps the repayment again.
        uint256 wethBefore = weth9.balanceOf(address(pool));
        shop.repay{value: 0.4 ether}(id);
        assertEq(weth9.balanceOf(address(pool)), wethBefore + 0.4 ether);
        assertEq(pool.totalBorrowed(), 0);
        assertEq(nft.ownerOf(1), alice);
        // The only ETH resting in the pool is what backs bob's unclaimed redemption credit.
        assertEq(address(pool).balance, pool.totalClaimable());
        assertEq(address(pool).balance, assets);
        // 5 deposited - 1 withdrawn - 0.4 borrowed + 0.0102 lender fee share - redeemed + 0.4 repaid.
        assertEq(weth9.balanceOf(address(pool)), 4.0102 ether - assets);
    }

    /// @dev Documents the dependency: settlement needs the collection to honour `transferFrom` to the
    /// borrower. While it refuses, repayment reverts whole and the loan keeps ageing (reported, low).
    function test_repayIsBlockedWhileTheCollectionRefusesTransfersAndResumesAfter() public {
        uint256 id = _pawn(1, 0);
        nft.setFailTransfers(true);
        uint256 aliceBefore = alice.balance;
        vm.prank(alice);
        vm.expectRevert("mock transfer failed");
        shop.repay{value: 0.4 ether}(id);
        assertEq(alice.balance, aliceBefore);
        assertTrue(shop.loanActive(id));
        assertEq(pool.totalBorrowed(), 0.4 ether);
        assertEq(shop.collectionDebt(address(nft)), 0.4 ether);
        assertEq(nft.ownerOf(1), shop.getLoan(id).vault);
        nft.setFailTransfers(false);
        vm.prank(alice);
        shop.repay{value: 0.4 ether}(id);
        assertEq(nft.ownerOf(1), alice);
        assertEq(pool.totalBorrowed(), 0);
    }

    receive() external payable {}
}
