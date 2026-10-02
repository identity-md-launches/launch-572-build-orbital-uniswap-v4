// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {OrbitalFixture} from "./utils/OrbitalFixture.sol";
import {OrbitalHook} from "../src/OrbitalHook.sol";
import {OrbitalMath} from "../src/libraries/OrbitalMath.sol";
import {BaseHook} from "../src/base/BaseHook.sol";
import {HookFlags} from "../src/HookFlags.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {CustomRevert} from "v4-core/src/libraries/CustomRevert.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockERC20Decimals} from "./mocks/MockERC20Decimals.sol";
import {MockERC20FeeOnTransfer} from "./mocks/MockERC20FeeOnTransfer.sol";
import {MockERC20ReturnsFalse} from "./mocks/MockERC20ReturnsFalse.sol";

/// @dev A contract that unlocks the PoolManager itself and, from inside the lock, tries to drive
/// the hook's settlement path or move the hook's claims directly.
contract Intruder is IUnlockCallback {
    IPoolManager immutable manager;
    OrbitalHook immutable hook;
    bytes4 public lastError;
    uint256 public attempt;

    constructor(IPoolManager _manager, OrbitalHook _hook) {
        manager = _manager;
        hook = _hook;
    }

    function attack(uint256 which, bytes calldata data) external {
        attempt = which;
        manager.unlock(data);
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (attempt == 0) {
            try hook.unlockCallback(data) {}
            catch (bytes memory err) {
                lastError = bytes4(err);
            }
        } else {
            (address token, uint256 amount) = abi.decode(data, (address, uint256));
            try manager.burn(address(hook), uint256(uint160(token)), amount) {}
            catch (bytes memory err) {
                lastError = bytes4(err);
            }
        }
        return "";
    }
}

/// @notice Failure paths and edge inputs the main suite does not cover: hostile tokens, hostile
/// callers, extreme amounts, boundary deposits, fee edge values and the sharing of one sphere
/// across several v4 pools.
contract OrbitalHookEdgeTest is OrbitalFixture {
    using PoolIdLibrary for PoolKey;

    uint256 constant R = 1_000_000e18;
    address lp2 = makeAddr("lp2");

    function setUp() public override {
        super.setUp();
        fund(lp2, 100_000_000);
    }

    function seed() internal {
        depositAs(lp, TIGHT, R);
        depositAs(lp, WIDE, 2 * R);
    }

    function claims(address token) internal view returns (uint256) {
        return manager.balanceOf(address(hook), uint256(uint160(token)));
    }

    function innerSelector(bytes memory err) internal pure returns (bytes4 sel) {
        if (err.length < 4) return bytes4(0);
        sel = bytes4(err);
        if (sel != CustomRevert.WrappedError.selector) return sel;
        bytes memory body = new bytes(err.length - 4);
        for (uint256 i = 0; i < body.length; i++) {
            body[i] = err[i + 4];
        }
        (,, bytes memory reason,) = abi.decode(body, (address, bytes4, bytes, bytes));
        return innerSelector(reason);
    }

    function trySwap(address who, PoolKey memory key, bool z, int256 amt) internal returns (bool ok, bytes4 sel) {
        vm.prank(who);
        try swapRouter.swap(
            key,
            SwapParams({
                zeroForOne: z,
                amountSpecified: amt,
                sqrtPriceLimitX96: z ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        ) {
            ok = true;
        } catch (bytes memory e) {
            sel = innerSelector(e);
        }
    }

    function keyFor(OrbitalHook h, address a, address b) internal pure returns (PoolKey memory) {
        (address c0, address c1) = a < b ? (a, b) : (b, a);
        return PoolKey({
            currency0: Currency.wrap(c0),
            currency1: Currency.wrap(c1),
            fee: 0,
            tickSpacing: 60,
            hooks: IHooks(address(h))
        });
    }

    /// @dev Deploys at a correctly mined address so constructor validation is what reverts.
    function deployRawDecimals(address[] memory b, uint8[] memory decs, uint256[] memory ks, uint24 fee) internal {
        bytes memory code = abi.encodePacked(
            type(OrbitalHook).creationCode,
            abi.encode(IPoolManager(address(manager)), owner, guardian, b, decs, ks, fee)
        );
        bytes32 salt = mineSalt(address(this), code, FLAGS);
        new OrbitalHook{salt: salt}(IPoolManager(address(manager)), owner, guardian, b, decs, ks, fee);
    }

    function twoLevelsN2() internal pure returns (uint256[] memory ks) {
        ks = new uint256[](2);
        ks[0] = 0.5e18; // N = 2: (√2 − 1, 1/√2] = (0.414, 0.707]
        ks[1] = 0.7e18;
    }

    // ---- hostile tokens ---------------------------------------------------------------------

    function test_feeOnTransferBasketTokenCannotDeposit() public {
        MockERC20FeeOnTransfer fot = new MockERC20FeeOnTransfer("Fee USD", "FUSD", 18, 100); // 1% fee
        address[] memory b = new address[](2);
        b[0] = address(usdA);
        b[1] = address(fot);
        OrbitalHook h = deployHook(owner, guardian, b, decimalsOf(b), twoLevelsN2(), FEE_PPM);
        fot.mint(lp, 1_000_000e18);
        vm.startPrank(lp);
        fot.approve(address(h), type(uint256).max);
        usdA.approve(address(h), type(uint256).max);
        uint256[] memory max = new uint256[](2);
        max[0] = type(uint256).max;
        max[1] = type(uint256).max;
        // The manager receives less than the hook credits itself for: the unlock cannot settle.
        vm.expectRevert(IPoolManager.CurrencyNotSettled.selector);
        h.deposit(1, R, max);
        vm.stopPrank();
        assertEq(h.totalRadius(), 0, "nothing was recorded");
        assertEq(fot.balanceOf(address(manager)), 0, "nothing was kept");
    }

    function test_transferFromReturningFalseIsAFailure() public {
        MockERC20ReturnsFalse bad = new MockERC20ReturnsFalse();
        address[] memory b = new address[](2);
        b[0] = address(usdA);
        b[1] = address(bad);
        OrbitalHook h = deployHook(owner, guardian, b, decimalsOf(b), twoLevelsN2(), FEE_PPM);
        bad.mint(lp, 1_000_000e18);
        vm.startPrank(lp);
        bad.approve(address(h), type(uint256).max);
        usdA.approve(address(h), type(uint256).max);
        uint256[] memory max = new uint256[](2);
        max[0] = type(uint256).max;
        max[1] = type(uint256).max;
        vm.expectRevert(OrbitalHook.TransferFailed.selector);
        h.deposit(1, R, max);
        // Once the token behaves, the same deposit goes through.
        bad.setFailTransfers(false);
        uint256[] memory amounts = h.deposit(1, R, max);
        vm.stopPrank();
        assertGt(amounts[1], 0);
        assertEq(bad.balanceOf(address(manager)), amounts[1]);
    }

    function test_basketTokenWithoutCodeCanNeverBeDeposited() public {
        address ghost = makeAddr("not-a-contract");
        address[] memory b = new address[](2);
        b[0] = address(usdA);
        b[1] = ghost;
        uint8[] memory decs = new uint8[](2);
        decs[0] = 18;
        decs[1] = 18;
        // The constructor makes no external calls, so it accepts the address...
        OrbitalHook h = deployHook(owner, guardian, b, decs, twoLevelsN2(), FEE_PPM);
        uint256[] memory max = new uint256[](2);
        max[0] = type(uint256).max;
        max[1] = type(uint256).max;
        // ...but no deposit can ever succeed, so no funds can be stranded behind it.
        vm.prank(lp);
        vm.expectRevert();
        h.deposit(1, R, max);
        assertEq(h.totalRadius(), 0);
    }

    // ---- hostile callers --------------------------------------------------------------------

    function test_intruderCannotDriveTheHooksSettlement() public {
        seed();
        Intruder intruder = new Intruder(IPoolManager(address(manager)), hook);
        uint256[] memory amounts = new uint256[](3);
        amounts[0] = 1e18;
        bytes memory data = abi.encode(
            OrbitalHook.CallbackData({
                action: OrbitalHook.Action.Withdraw, account: address(intruder), amounts: amounts
            })
        );
        uint256 before = claims(address(usdA));
        intruder.attack(0, data);
        assertEq(intruder.lastError(), BaseHook.NotPoolManager.selector, "unlockCallback refused the intruder");
        assertEq(claims(address(usdA)), before, "claims untouched");
        assertEq(usdA.balanceOf(address(intruder)), 0);

        intruder.attack(1, abi.encode(address(usdA), uint256(1e18)));
        assertTrue(intruder.lastError() != bytes4(0), "manager refused to burn the hook's claims for a stranger");
        assertEq(claims(address(usdA)), before, "claims untouched");
    }

    function test_withdrawWithoutPositionIsRefused() public {
        seed();
        vm.prank(trader);
        vm.expectRevert(OrbitalHook.InsufficientPosition.selector);
        hook.withdraw(WIDE, 1, zeros());
        vm.prank(trader);
        vm.expectRevert(OrbitalHook.InvalidLevel.selector);
        hook.withdraw(3, 1, zeros());
        vm.prank(trader);
        vm.expectRevert(OrbitalHook.LengthMismatch.selector);
        hook.withdraw(WIDE, 1, new uint256[](2));
    }

    function test_collectFeesEdges() public {
        seed();
        vm.expectRevert(OrbitalHook.InvalidLevel.selector);
        hook.collectFees(3);
        // A stranger collects nothing and nothing moves.
        uint256 before = usdA.balanceOf(address(manager));
        vm.prank(trader);
        uint256[] memory got = hook.collectFees(WIDE);
        assertEq(got[0] + got[1] + got[2], 0);
        assertEq(usdA.balanceOf(address(manager)), before);
        // Collecting twice pays once.
        swapAs(trader, keyAB, isZeroForOne(keyAB, address(usdA)), -100_000e18);
        vm.startPrank(lp);
        uint256[] memory first = hook.collectFees(WIDE);
        uint256[] memory second = hook.collectFees(WIDE);
        vm.stopPrank();
        assertGt(first[hook.tokenIndex(address(usdA)) - 1], 0);
        assertEq(second[0] + second[1] + second[2], 0, "second collection pays nothing");
    }

    function test_feesAreSplitByRadiusAcrossLps() public {
        depositAs(lp, WIDE, R);
        depositAs(lp2, WIDE, 3 * R);
        uint256 idxA = hook.tokenIndex(address(usdA)) - 1;
        swapAs(trader, keyAB, isZeroForOne(keyAB, address(usdA)), -100_000e18);
        uint256 fee = 100_000e18 * uint256(FEE_PPM) / 1_000_000;
        uint256 a = hook.pendingFees(WIDE, lp)[idxA];
        uint256 b = hook.pendingFees(WIDE, lp2)[idxA];
        assertCloseBps(a, fee / 4, 1, "lp: a quarter");
        assertCloseBps(b, 3 * fee / 4, 1, "lp2: three quarters");
        assertLe(a + b, fee, "never pays out more than was charged");
        // A later LP earns nothing from earlier swaps.
        depositAs(trader, WIDE, R);
        assertEq(hook.pendingFees(WIDE, trader)[idxA], 0);
    }

    // ---- extreme amounts --------------------------------------------------------------------

    function test_hugeSwapsRevertInsteadOfOverflowing() public {
        seed();
        bool z = isZeroForOne(keyAB, address(usdA));
        // The largest input v4 can carry: the squares in the invariant overflow 256 bits, which
        // surfaces as an arithmetic panic; still a revert, never a mispriced trade.
        (bool ok, bytes4 sel) = trySwap(trader, keyAB, z, -int256(uint256(type(uint128).max)));
        assertFalse(ok, "uint128 max exact-in");
        // An input beyond every tick's range pins every tick and is refused for lack of interior.
        (ok, sel) = trySwap(trader, keyAB, z, -int256(uint256(1e30)));
        assertFalse(ok);
        assertEq(sel, OrbitalHook.NoInteriorLiquidity.selector, "exact-in past every tick");
        (ok, sel) = trySwap(trader, keyAB, z, int256(uint256(type(uint128).max)));
        assertFalse(ok);
        assertEq(sel, OrbitalMath.InsufficientLiquidity.selector, "exact-out beyond the reserve");
        // Exact-out of exactly the whole real reserve of the output token is refused too.
        uint256 idxB = hook.tokenIndex(address(usdB)) - 1;
        uint256 realB = hook.realReserves()[idxB];
        (ok, sel) = trySwap(trader, keyAB, z, int256(realB));
        assertFalse(ok, "cannot drain the output token to its floor");
    }

    function test_oneWeiSwapsNeverPayOutMoreThanPar() public {
        seed();
        bool z = isZeroForOne(keyAB, address(usdA));
        uint256 b0 = usdB.balanceOf(trader);
        uint256 a0 = usdA.balanceOf(trader);
        // Opening the pool rounds the equal-price point up by at most r/(N·1e18) per coin, so the
        // state point starts a hair inside the sphere. The first trade, however small, collects that
        // dust (a few million wei here, ~1e-12 of a token for 3e24 of radius) and leaves the point on
        // the surface; it can never collect more than the opening rounding.
        uint256 openingDust = hook.n() * hook.totalRadius() / 1e18 + 1;
        swapAs(trader, keyAB, z, -1);
        assertLe(usdB.balanceOf(trader) - b0, 1 + openingDust, "one wei in buys at most one wei plus the opening dust");
        assertEq(a0 - usdA.balanceOf(trader), 1);
        // From a point on the surface: one wei in buys at most two wei (α is tracked in units of
        // 1/√N wei of Σx, so one wei of either coin can move it by one unit or none).
        b0 = usdB.balanceOf(trader);
        swapAs(trader, keyAB, z, -1);
        assertLe(usdB.balanceOf(trader) - b0, 2, "one wei in, at most par plus one wei of rounding");
        assertEq(a0 - usdA.balanceOf(trader), 2);
        // One wei out costs at least one wei in, fee included.
        swapAs(trader, keyAB, z, 1);
        assertGe(a0 - usdA.balanceOf(trader), 3);
        // One raw unit of the 6-decimal coin out costs about 1e12 wei of an 18-decimal coin.
        uint256 paid = hook.quoteExactOutput(address(usdA), address(usdC), 1);
        assertGe(paid, 1e12, "never below par for one unit");
        assertLt(paid, 2e12);
    }

    function test_quoteRejectsBadTokens() public {
        seed();
        MockERC20 orb = new MockERC20("Orbital", "ORB", 1e27);
        vm.expectRevert(OrbitalHook.InvalidTokens.selector);
        hook.quoteExactInput(address(orb), address(usdA), 1e18);
        vm.expectRevert(OrbitalHook.InvalidTokens.selector);
        hook.quoteExactInput(address(usdA), address(usdA), 1e18);
        vm.expectRevert(OrbitalHook.InvalidTokens.selector);
        hook.quoteExactOutput(address(usdA), address(orb), 1e18);
        vm.expectRevert(OrbitalHook.ZeroAmount.selector);
        hook.quoteExactInput(address(usdA), address(usdB), 0);
        vm.expectRevert(OrbitalHook.ZeroAmount.selector);
        hook.quoteExactOutput(address(usdA), address(usdB), 0);
    }

    function test_quotesRefuseBeforeAnyLiquidity() public {
        vm.expectRevert(OrbitalHook.NoInteriorLiquidity.selector);
        hook.quoteExactInput(address(usdA), address(usdB), 1e18);
        vm.expectRevert(OrbitalHook.NoInteriorLiquidity.selector);
        hook.quoteExactOutput(address(usdA), address(usdB), 1e18);
        assertEq(hook.alphaIntNorm(), type(int256).max, "no interior: position undefined");
        (uint256 r, uint256 kb, uint256 sb) = hook.consolidated();
        assertEq(r + kb + sb, 0);
        assertEq(sum(hook.levelReserves(WIDE)), 0);
        assertEq(sum(hook.realReserves()), 0);
    }

    // ---- exact-out across a tick, and the sphere shared by every pool -----------------------

    function test_exactOutCrossesTickAndMatchesQuote() public {
        seed();
        bool z = isZeroForOne(keyAB, address(usdA));
        uint256 want = 500_000e18;
        uint256 quoted = hook.quoteExactOutput(address(usdA), address(usdB), want);
        uint256 a0 = usdA.balanceOf(trader);
        uint256 b0 = usdB.balanceOf(trader);
        vm.expectEmit(true, false, false, true, address(hook));
        emit OrbitalHook.LevelCrossed(TIGHT, true);
        swapAs(trader, keyAB, z, int256(want));
        assertEq(usdB.balanceOf(trader) - b0, want);
        assertEq(a0 - usdA.balanceOf(trader), quoted, "exact-out quote matches across a crossing");
        assertEq(hook.boundaryMask(), 1 << TIGHT);
        (uint256 r,,) = hook.consolidated();
        int256 f = hook.invariant();
        assertLe(f < 0 ? uint256(-f) : uint256(f), r * r / 1e12 + 1e40, "on the torus after the crossing");
    }

    function test_allOrbitalPoolsShareOneSphere() public {
        seed();
        uint256 quoteAC = hook.quoteExactInput(address(usdA), address(usdC), 1_000e18);
        uint256 quoteBC = hook.quoteExactInput(address(usdB), address(usdC), 1_000e18);
        // Dumping A for B on the A/B pool makes A cheaper everywhere and B dearer everywhere.
        swapAs(trader, keyAB, isZeroForOne(keyAB, address(usdA)), -300_000e18);
        assertLt(hook.quoteExactInput(address(usdA), address(usdC), 1_000e18), quoteAC, "A buys less C");
        assertGt(hook.quoteExactInput(address(usdB), address(usdC), 1_000e18), quoteBC, "B buys more C");
        // A second v4 pool over the same pair (different fee tier) is registered on the same sphere.
        PoolKey memory k2 = keyAB;
        k2.fee = 3_000;
        k2.tickSpacing = 10;
        manager.initialize(k2, SQRT_PRICE_1_1);
        (bool orbital,,) = hook.pools(k2.toId());
        assertTrue(orbital);
        uint256 q = hook.quoteExactInput(address(usdA), address(usdB), 1_000e18);
        uint256 b0 = usdB.balanceOf(trader);
        swapAs(trader, k2, isZeroForOne(k2, address(usdA)), -1_000e18);
        assertEq(usdB.balanceOf(trader) - b0, q, "same price on the second pool");
    }

    // ---- deposits at the boundary -----------------------------------------------------------

    function test_depositIntoPinnedTickThenUnpinAndExit() public {
        seed();
        swapAs(trader, keyAB, isZeroForOne(keyAB, address(usdA)), -600_000e18);
        assertEq(hook.boundaryMask(), 1 << TIGHT);
        uint256[] memory preview = hook.previewDeposit(TIGHT, R);
        uint256[] memory put = depositAs(lp2, TIGHT, R);
        for (uint256 k = 0; k < 3; k++) {
            assertEq(put[k], preview[k], "preview matches a boundary deposit");
        }
        assertEq(hook.boundaryMask(), 1 << TIGHT, "still pinned");
        (uint256 r,,) = hook.consolidated();
        int256 f = hook.invariant();
        assertLe(f < 0 ? uint256(-f) : uint256(f), r * r / 1e12 + 1e40, "boundary deposit keeps the torus");
        // The pinned tick (now 2R) is isolated: on a deepening depeg it absorbs far less of the
        // depegging coin than the equally sized full-range tick, and never more than its plane cap.
        uint256 idxA = hook.tokenIndex(address(usdA)) - 1;
        uint256 tightBefore = hook.levelReserves(TIGHT)[idxA];
        uint256 wideBefore = hook.levelReserves(WIDE)[idxA];
        swapAs(trader, keyAC, isZeroForOne(keyAC, address(usdA)), -200_000e18);
        uint256 tightDelta = hook.levelReserves(TIGHT)[idxA] - tightBefore;
        uint256 wideDelta = hook.levelReserves(WIDE)[idxA] - wideBefore;
        assertLt(tightDelta * 5, wideDelta, "pinned tick absorbs < 1/5 of what the full-range tick absorbs");
        OrbitalHook.Level memory L = hook.level(TIGHT);
        uint256 cap = 2 * R * L.kNorm / 1e18 * 1e18 / hook.sqrtN() + 2 * R * L.sNorm / 1e18
            * OrbitalMath.sqrt(uint256(2e36) / 3) / 1e18;
        assertLe(hook.levelReserves(TIGHT)[idxA], cap + 1e12, "under the geometric cap");
        // Back to the peg: the tick rejoins, and the new LP can exit with a consistent amount.
        uint256 bBal = usdB.balanceOf(trader);
        swapAs(trader, keyAB, isZeroForOne(keyAB, address(usdB)), -int256(bBal > 550_000e18 ? 550_000e18 : bBal));
        assertEq(hook.boundaryMask(), 0, "unpinned");
        vm.prank(lp2);
        uint256[] memory got = hook.withdraw(TIGHT, R, zeros());
        assertGt(got[0], 0);
        assertGt(got[1], 0);
        assertGt(got[2], 0);
        // Everyone else can leave too and the manager keeps only dust.
        vm.startPrank(lp);
        hook.withdraw(TIGHT, R, zeros());
        hook.withdraw(WIDE, 2 * R, zeros());
        hook.collectFees(TIGHT);
        hook.collectFees(WIDE);
        vm.stopPrank();
        vm.prank(lp2);
        hook.collectFees(TIGHT);
        assertEq(hook.totalRadius(), 0);
        assertLt(usdA.balanceOf(address(manager)), 1e12);
        assertLt(usdB.balanceOf(address(manager)), 1e12);
        assertLt(usdC.balanceOf(address(manager)), 10);
    }

    function test_emptyTickDepositedPastItsPlaneOpensPinned() public {
        depositAs(lp, TIGHT, R);
        depositAs(lp, WIDE, R);
        // A plane as far out as k = 0.95 (N = 3) cannot be reached by one coin depegging: the pole
        // of that coin comes first. Two coins depegging at once (A and B both dumped for C) reach it.
        for (uint256 i = 0; i < 60 && hook.alphaIntNorm() <= int256(K_MID); i++) {
            PoolKey memory k = i % 2 == 0 ? keyAC : keyBC;
            address tokenIn = i % 2 == 0 ? address(usdA) : address(usdB);
            (bool ok,) = trySwap(trader, k, isZeroForOne(k, tokenIn), -50_000e18);
            if (!ok) break;
        }
        assertGt(hook.alphaIntNorm(), int256(K_MID), "interior beyond the mid plane");
        assertEq(hook.boundaryMask() & (1 << MID), 0, "empty tick carries no bit yet");
        depositAs(lp2, MID, R);
        assertEq(hook.boundaryMask() & (1 << MID), 1 << MID, "opened directly as a boundary tick");
        (uint256 r, uint256 kb,) = hook.consolidated();
        assertGt(kb, 0);
        int256 f = hook.invariant();
        assertLe(f < 0 ? uint256(-f) : uint256(f), r * r / 1e12 + 1e40, "torus holds");
        // The pinned mid tick is confined to its plane: whatever the next trade does, no coin it
        // holds can exceed the plane's geometric cap r·(k/√N + s·√((N−1)/N)).
        swapAs(trader, keyAC, isZeroForOne(keyAC, address(usdA)), -5_000e18);
        OrbitalHook.Level memory L = hook.level(MID);
        uint256 cap =
            R * L.kNorm / 1e18 * 1e18 / hook.sqrtN() + R * L.sNorm / 1e18 * OrbitalMath.sqrt(uint256(2e36) / 3) / 1e18;
        uint256[] memory midNow = hook.levelReserves(MID);
        for (uint256 k = 0; k < 3; k++) {
            assertLe(midNow[k], cap + 1e12, "pinned tick reserve exceeds its plane cap");
        }
        assertEq(hook.boundaryMask() & (1 << MID), 1 << MID, "still pinned");
        vm.prank(lp2);
        uint256[] memory got = hook.withdraw(MID, R, zeros());
        assertGt(got[0] + got[1] + got[2], 0);
    }

    function test_pinnedLpCanAlwaysLeaveEvenWhenNoInteriorRemains() public {
        depositAs(lp, TIGHT, R);
        depositAs(lp2, WIDE, 2 * R);
        swapAs(trader, keyAB, isZeroForOne(keyAB, address(usdA)), -600_000e18);
        assertEq(hook.boundaryMask(), 1 << TIGHT);
        uint256[] memory tightNow = hook.levelReserves(TIGHT);
        vm.prank(lp2);
        hook.withdraw(WIDE, 2 * R, zeros());
        (uint256 r,,) = hook.consolidated();
        assertEq(r, 0, "only pinned liquidity remains");
        // Funds are never trapped: the pinned LP withdraws its full plane vector minus the floor,
        // plus the fees it accrued.
        uint256 idxA = hook.tokenIndex(address(usdA)) - 1;
        uint256 before = usdA.balanceOf(lp);
        uint256 fees = hook.pendingFees(TIGHT, lp)[idxA];
        vm.prank(lp);
        uint256[] memory got = hook.withdraw(TIGHT, R, zeros());
        OrbitalHook.Level memory L = hook.level(TIGHT);
        assertEq(got[idxA], tightNow[idxA] - R * L.xMinNorm / 1e18, "plane vector minus floor");
        assertEq(usdA.balanceOf(lp), before + got[idxA] + fees);
        assertEq(hook.totalRadius(), 0);
    }

    function test_depositWhileAllPinnedOnlyIntoThePinnedTick() public {
        depositAs(lp, TIGHT, R);
        depositAs(lp2, WIDE, 2 * R);
        swapAs(trader, keyAB, isZeroForOne(keyAB, address(usdA)), -600_000e18);
        vm.prank(lp2);
        hook.withdraw(WIDE, 2 * R, zeros());
        // Adding to the pinned tick itself still works and lands on its plane.
        uint256[] memory put = depositAs(lp2, TIGHT, R);
        assertGt(put[0] + put[1] + put[2], 0);
        assertEq(hook.level(TIGHT).radius, 2 * R);
        assertEq(hook.boundaryMask(), 1 << TIGHT);
        // Nothing trades without an interior, and nothing is stuck: a deposit into an empty tick
        // above the pinned plane opens a fresh interior exactly on that plane and trading resumes.
        (bool ok, bytes4 sel) = trySwap(trader, keyAB, isZeroForOne(keyAB, address(usdB)), -1e18);
        assertFalse(ok);
        assertEq(sel, OrbitalHook.NoInteriorLiquidity.selector);
        depositAs(lp, MID, R);
        (uint256 r,,) = hook.consolidated();
        assertEq(r, R, "interior reopened");
        assertApproxEqAbs(hook.alphaIntNorm(), int256(K_TIGHT), 10, "on the pinned plane");
        (ok,) = trySwap(trader, keyAB, isZeroForOne(keyAB, address(usdB)), -1e18);
        assertTrue(ok, "trading resumed");
    }

    // ---- fee edge values --------------------------------------------------------------------

    function test_zeroFeeSwapAccruesNothing() public {
        seed();
        vm.prank(owner);
        hook.setFee(0);
        uint256 idxA = hook.tokenIndex(address(usdA)) - 1;
        uint256 b0 = usdB.balanceOf(trader);
        swapAs(trader, keyAB, isZeroForOne(keyAB, address(usdA)), -1_000e18);
        uint256 out = usdB.balanceOf(trader) - b0;
        assertLt(out, 1_000e18, "still pays the curve's spread");
        assertCloseBps(1_000e18, out, 10, "within 10 bps of par with no fee");
        assertEq(hook.pendingFees(WIDE, lp)[idxA], 0, "no fee accrued");
        assertEq(hook.pendingFees(TIGHT, lp)[idxA], 0);
    }

    function test_maxFeeSwapChargesOnePercent() public {
        seed();
        uint24 maxFee = hook.MAX_FEE_PPM();
        vm.prank(owner);
        hook.setFee(maxFee);
        uint256 idxA = hook.tokenIndex(address(usdA)) - 1;
        swapAs(trader, keyAB, isZeroForOne(keyAB, address(usdA)), -1_000e18);
        uint256 feeTight = hook.pendingFees(TIGHT, lp)[idxA];
        uint256 feeWide = hook.pendingFees(WIDE, lp)[idxA];
        assertCloseBps(10e18, feeTight + feeWide, 1, "1% of the input, split by radius");
        // Exact-out at 1%: paying for 1_000 B costs > 1_010 A? No: ≈ 1_000 / 0.99 plus spread.
        uint256 paid = hook.quoteExactOutput(address(usdA), address(usdB), 1_000e18);
        assertGt(paid, uint256(1_000e18) * 100 / 99);
        assertLt(paid, uint256(1_000e18) * 102 / 99);
    }

    // ---- constructor bounds -----------------------------------------------------------------

    function test_constructorBoundsOnBasketAndLevels() public {
        uint256[] memory ks = new uint256[](1);
        ks[0] = K_WIDE;
        address[] memory nine = new address[](9);
        uint8[] memory nineDecs = new uint8[](9);
        for (uint256 i = 0; i < 9; i++) {
            nine[i] = address(new MockERC20("T", "T", 0));
            nineDecs[i] = 18;
        }
        vm.expectRevert(OrbitalHook.InvalidTokens.selector);
        deployRawDecimals(nine, nineDecs, ks, FEE_PPM);

        uint256[] memory none = new uint256[](0);
        vm.expectRevert(OrbitalHook.InvalidLevels.selector);
        deployRawDecimals(basket, decimalsOf(basket), none, FEE_PPM);

        uint256[] memory nineK = new uint256[](9);
        for (uint256 i = 0; i < 9; i++) {
            nineK[i] = 0.74e18 + i * 0.04e18;
        }
        vm.expectRevert(OrbitalHook.InvalidLevels.selector);
        deployRawDecimals(basket, decimalsOf(basket), nineK, FEE_PPM);

        // k exactly at √N − 1 (the equal-price point) is excluded; k exactly at (N−1)/√N is allowed.
        uint256 s3 = OrbitalMath.sqrtN(3);
        uint256[] memory edge = new uint256[](1);
        edge[0] = s3 - 1e18;
        vm.expectRevert(OrbitalHook.InvalidLevels.selector);
        deployRawDecimals(basket, decimalsOf(basket), edge, FEE_PPM);
        edge[0] = 2 * 1e36 / s3;
        OrbitalHook full = deployHook(owner, guardian, basket, decimalsOf(basket), edge, FEE_PPM);
        assertLe(full.level(0).xMinNorm, 1e6, "full-range tick has no floor");
        assertEq(full.n(), 3);
    }

    function test_eightTokenBasketWorksEndToEnd() public {
        address[] memory b = new address[](8);
        uint8[] memory decs = new uint8[](8);
        for (uint256 i = 0; i < 8; i++) {
            MockERC20Decimals t = new MockERC20Decimals("T", "T", uint8(6 + 2 * i)); // 6..20 → cap at 18
            if (6 + 2 * i > 18) t = new MockERC20Decimals("T", "T", 18);
            b[i] = address(t);
            decs[i] = t.decimals();
        }
        uint256 s8 = OrbitalMath.sqrtN(8); // 2√2
        uint256[] memory ks = new uint256[](2);
        ks[0] = s8 - 1e18 + 0.05e18;
        ks[1] = 7 * 1e36 / s8; // full range
        OrbitalHook h = deployHook(owner, guardian, b, decs, ks, FEE_PPM);
        assertEq(h.n(), 8);
        uint256[] memory max = new uint256[](8);
        for (uint256 i = 0; i < 8; i++) {
            MockERC20Decimals(b[i]).mint(lp, 1e40);
            vm.prank(lp);
            MockERC20Decimals(b[i]).approve(address(h), type(uint256).max);
            max[i] = type(uint256).max;
        }
        vm.prank(lp);
        uint256[] memory amounts = h.deposit(1, R, max);
        // Equal-price point for N = 8: xᵢ = r(1 − 1/√8) ≈ 0.6464 r, in each token's own decimals.
        for (uint256 i = 0; i < 8; i++) {
            assertCloseBps(amounts[i] * h.scale(i), R - R * 1e18 / s8, 1, "equal point");
        }
        // Swap between two of them through a pool.
        PoolKey memory k = keyFor(h, b[0], b[7]);
        manager.initialize(k, SQRT_PRICE_1_1);
        MockERC20Decimals(b[0]).mint(trader, 1e30);
        vm.prank(trader);
        MockERC20Decimals(b[0]).approve(address(swapRouter), type(uint256).max);
        uint256 q = h.quoteExactInput(b[0], b[7], 1_000e6);
        uint256 before = MockERC20Decimals(b[7]).balanceOf(trader);
        swapAs(trader, k, isZeroForOne(k, b[0]), -1_000e6);
        assertEq(MockERC20Decimals(b[7]).balanceOf(trader) - before, q);
        // On the sphere the price impact of Δ is Δ / (r/√N) = 0.28% here, plus the 0.04% fee.
        assertCloseBps(1_000e18, q, 50, "near par");
        assertLt(q, 1_000e18 - 1_000e18 * uint256(FEE_PPM) / 1_000_000, "pays fee and spread");
    }

    // ---- pause edges ------------------------------------------------------------------------

    function test_pauseIsIdempotentAndOnlyEmitsOnChange() public {
        vm.startPrank(owner);
        vm.expectEmit(true, false, false, true, address(hook));
        emit OrbitalHook.Paused(owner, false);
        hook.pause();
        vm.recordLogs();
        hook.pause(); // no-op
        assertEq(vm.getRecordedLogs().length, 0, "second pause emits nothing");
        hook.unpause();
        hook.unpause(); // unpausing an unpaused pool is harmless
        assertFalse(hook.paused());
        vm.stopPrank();
        // Guardian pause after an owner pause changes nothing and emits nothing.
        vm.prank(owner);
        hook.pause();
        vm.recordLogs();
        vm.prank(guardian);
        hook.guardianPause();
        assertEq(vm.getRecordedLogs().length, 0);
    }

    function test_pauseBlocksOrbitalPoolInitialisationToo() public {
        MockERC20 usdD = new MockERC20("USD D", "USDD", 0);
        address[] memory b = new address[](2);
        b[0] = address(usdA);
        b[1] = address(usdD);
        OrbitalHook h = deployHook(owner, guardian, b, decimalsOf(b), twoLevelsN2(), FEE_PPM);
        vm.prank(guardian);
        h.guardianPause();
        PoolKey memory k = keyFor(h, address(usdA), address(usdD));
        vm.expectRevert();
        manager.initialize(k, SQRT_PRICE_1_1);
        vm.prank(owner);
        h.unpause();
        manager.initialize(k, SQRT_PRICE_1_1);
        (bool orbital,,) = h.pools(k.toId());
        assertTrue(orbital);
    }

    function test_rotatedGuardianLosesPausePower() public {
        vm.prank(owner);
        hook.setGuardian(trader);
        vm.prank(guardian);
        vm.expectRevert(OrbitalHook.NotGuardian.selector);
        hook.guardianPause();
        vm.prank(trader);
        hook.guardianPause();
        assertTrue(hook.paused());
        // Removing the guardian entirely disables the breaker but not the owner.
        vm.prank(owner);
        hook.setGuardian(address(0));
        vm.prank(owner);
        hook.unpause();
        vm.prank(trader);
        vm.expectRevert(OrbitalHook.NotGuardian.selector);
        hook.guardianPause();
        vm.prank(owner);
        hook.pause();
        assertTrue(hook.paused());
    }

    function test_formerOwnerLosesEverything() public {
        vm.prank(owner);
        hook.transferOwnership(trader);
        vm.startPrank(owner);
        vm.expectRevert(OrbitalHook.NotOwner.selector);
        hook.pause();
        vm.expectRevert(OrbitalHook.NotOwner.selector);
        hook.unpause();
        vm.expectRevert(OrbitalHook.NotOwner.selector);
        hook.setFee(1);
        vm.expectRevert(OrbitalHook.NotOwner.selector);
        hook.setGuardian(owner);
        vm.expectRevert(OrbitalHook.NotOwner.selector);
        hook.transferOwnership(owner);
        vm.stopPrank();
        assertEq(hook.owner(), trader);
    }

    // ---- fuzz: preview/actual, deposit-withdraw cycles ---------------------------------------

    /// forge-config: default.fuzz.runs = 300
    function testFuzz_depositWithdrawCycleNeverProfits(uint256 radius, uint256 levelSeed, uint256 swapAmt) public {
        seed();
        uint256 level = levelSeed % 3;
        radius = bound(radius, hook.MIN_RADIUS(), 5 * R);
        swapAmt = bound(swapAmt, 1e18, 400_000e18);
        // Move the price somewhere first so the cycle does not always run at the equal point.
        swapAs(trader, keyAB, isZeroForOne(keyAB, address(usdA)), -int256(swapAmt));
        uint256 a0 = usdA.balanceOf(lp2);
        uint256 b0 = usdB.balanceOf(lp2);
        uint256 c0 = usdC.balanceOf(lp2);
        uint256[] memory preview = hook.previewDeposit(level, radius);
        vm.prank(lp2);
        uint256[] memory put = hook.deposit(level, radius, preview);
        for (uint256 k = 0; k < 3; k++) {
            assertEq(put[k], preview[k], "preview bounds actual");
        }
        vm.prank(lp2);
        uint256[] memory got = hook.withdraw(level, radius, zeros());
        for (uint256 k = 0; k < 3; k++) {
            // Rounding: the share direction is WAD-scaled, so a 1e-18 relative error on 1e24-sized
            // reserves is ~1e6 wei either way (the direction is not strictly pool-favoured: a cycle
            // can end a few wei up, i.e. 1e-19 of the deposit), plus one raw unit for the 6-decimal
            // coin's ceil/floor pair.
            uint256 tol = put[k] / 1e12 + 2;
            assertLe(got[k], put[k] + tol, "withdraw exceeds deposit by more than rounding");
            assertGe(got[k] + tol, put[k], "withdraw loses more than rounding");
        }
        assertLe(usdA.balanceOf(lp2), a0 + a0 / 1e15);
        assertLe(usdB.balanceOf(lp2), b0 + b0 / 1e15);
        assertLe(usdC.balanceOf(lp2), c0);
    }

    /// forge-config: default.fuzz.runs = 300
    function testFuzz_exactOutNeverCheaperThanExactInAcrossTheSameSize(uint256 amount, bool viaC) public {
        seed();
        amount = bound(amount, 1e15, 300_000e18);
        address out = viaC ? address(usdC) : address(usdB);
        uint256 rawOut = viaC ? amount / 1e12 : amount;
        if (rawOut == 0) rawOut = 1;
        // Buying exactly what an exact-in trade of `amount` would yield costs at least `amount`.
        uint256 yield = hook.quoteExactInput(address(usdA), out, amount);
        if (yield == 0) return;
        uint256 cost = hook.quoteExactOutput(address(usdA), out, yield);
        // The exact-in output drops its sub-unit remainder (< one raw unit of `out`); buying only
        // the kept units is cheaper by that remainder grossed up by the fee, plus wei-level rounding.
        uint256 unit = viaC ? 1e12 : 1;
        uint256 slack = 2 * unit + amount / 1e6 + 4;
        assertLe(cost, amount + slack, "exact-out cost is consistent with exact-in");
        assertGe(cost + slack, amount, "and never materially cheaper");
    }
}
