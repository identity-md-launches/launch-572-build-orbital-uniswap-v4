// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary, toBeforeSwapDelta} from "v4-core/src/types/BeforeSwapDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {BaseHook} from "./base/BaseHook.sol";
import {OrbitalMath} from "./libraries/OrbitalMath.sol";

/// @title OrbitalHook
/// @notice Uniswap v4 hook implementing Paradigm's Orbital stableswap: one N-token pool whose
/// liquidity lies on an N-dimensional sphere, with concentrated "ticks" that are automatically
/// pinned (isolated) when a coin leaves the peg region they cover.
///
/// Every v4 pool whose two currencies are both basket tokens routes its swaps through the shared
/// sphere via `beforeSwap` + `beforeSwapReturnDelta`; v4's own curve is bypassed and LP positions
/// live here, not in the PoolManager (`beforeAddLiquidity` refuses them). Pools with any other
/// currency are left untouched ("pass-through"), apart from the circuit breaker.
///
/// Reserves are held as ERC-6909 claims on the PoolManager owned by this contract, so swaps settle
/// purely in claims and never depend on the manager's spot balance of a token.
///
/// Circuit breaker: a `guardian` (the Reactive callback contract) may only pause. Resuming is
/// owner-only so a human reviews the depeg first. Withdrawals always work, paused or not.
contract OrbitalHook is BaseHook, IUnlockCallback {
    using PoolIdLibrary for PoolKey;

    // ---- constants --------------------------------------------------------------------------

    uint256 public constant WAD = 1e18;
    uint256 public constant MAX_TOKENS = 8;
    uint256 public constant MAX_LEVELS = 8;
    uint256 public constant FEE_DENOMINATOR = 1_000_000; // parts per million, like v4
    uint24 public constant MAX_FEE_PPM = 10_000; // 1%
    uint256 public constant MAX_TOTAL_RADIUS = 1e30; // 10^12 tokens of radius
    /// @dev Smallest radius a tick or a position may hold (one unit of radius ≈ 0.42 tokens per
    /// coin at full range). Also the floor a partial withdrawal must leave behind, so the interior
    /// position is never derived from a wei-sized pool.
    uint256 public constant MIN_RADIUS = 1e18;
    /// @dev Slack, in WAD units of normalised interior position (1e-15), within which a tick is
    /// treated as sitting on its plane. Plane landings, deposits and withdrawals round the position
    /// by a few units; without the slack a tick one unit off its plane could be left on the wrong
    /// side by a trade that starts there.
    int256 internal constant POSITION_TOLERANCE = 1e3;

    // ---- types ------------------------------------------------------------------------------

    struct Level {
        uint256 kNorm; // tick plane per unit radius (WAD)
        uint256 sNorm; // boundary circle radius per unit radius (WAD)
        uint256 xMinNorm; // reserve floor per unit radius (WAD) — virtual, never deposited
        uint256 radius; // total radius currently in this level (WAD)
    }

    struct PoolMeta {
        bool orbital;
        uint8 idx0;
        uint8 idx1;
    }

    enum Action {
        Deposit,
        Withdraw, // deliver tokens, fall back to ERC-6909 claims for a coin that refuses to move
        Redeem // deliver tokens for claims the caller handed in; no fallback
    }

    struct CallbackData {
        Action action;
        address account;
        uint256[] amounts; // raw token units per basket token
    }

    // ---- storage ----------------------------------------------------------------------------

    address public owner;
    address public guardian;
    bool public paused;
    uint24 public feePpm;

    uint256 public immutable n;
    uint256 public immutable sqrtN;

    address[] internal _tokens;
    uint256[] internal _scale; // 10^(18 − decimals)
    mapping(address => uint256) public tokenIndex; // 1-based; 0 = not a basket token

    Level[] internal _levels;
    uint256 public boundaryMask; // bit l set ⇒ level l is pinned to its plane
    uint256 public totalRadius;
    uint256[] internal _x; // virtual reserves (WAD)

    mapping(PoolId => PoolMeta) public pools;
    mapping(uint256 => mapping(address => uint256)) public positions; // level ⇒ lp ⇒ radius
    uint256[] internal _feeGrowth; // per token, WAD-scaled fee per unit radius
    mapping(uint256 => mapping(address => mapping(uint256 => uint256))) internal _feeDebt;

    uint256 private _entered = 1;

    // ---- events -----------------------------------------------------------------------------

    event OrbitalPoolRegistered(PoolId indexed poolId, uint8 idx0, uint8 idx1);
    event Deposit(address indexed lp, uint256 indexed level, uint256 radius, uint256[] amounts);
    event Withdraw(address indexed lp, uint256 indexed level, uint256 radius, uint256[] amounts);
    event FeesCollected(address indexed lp, uint256 indexed level, uint256[] amounts);
    event ClaimsDelivered(address indexed account, address indexed token, uint256 amount);
    event ClaimsRedeemed(address indexed account, address indexed token, uint256 amount, address to);
    event OrbitalSwap(
        address indexed sender, uint8 tokenIn, uint8 tokenOut, uint256 amountIn, uint256 amountOut, uint256 feeWad
    );
    event LevelCrossed(uint256 indexed level, bool boundary);
    event Paused(address indexed by, bool byGuardian);
    event Unpaused(address indexed by);
    event GuardianUpdated(address indexed guardian);
    event FeeUpdated(uint24 feePpm);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    // ---- errors -----------------------------------------------------------------------------

    error NotOwner();
    error NotGuardian();
    error IsPaused();
    error ZeroAddress();
    error InvalidTokens();
    error InvalidLevels();
    error InvalidLevel();
    error FeeTooHigh();
    error Reentrancy();
    error LiquidityLivesInHook();
    error ZeroAmount();
    error RadiusTooSmall();
    error RadiusCapExceeded();
    error SlippageExceeded();
    error InsufficientPosition();
    error NoInteriorLiquidity();
    error TooManyCrossings();
    error SwapTooLarge();
    error AmountOverflow();
    error TransferFailed();
    error LengthMismatch();
    error ResidualTooSmall();
    error BoundaryInverted();

    // ---- modifiers --------------------------------------------------------------------------

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    modifier whenNotPaused() {
        if (paused) revert IsPaused();
        _;
    }

    modifier nonReentrant() {
        if (_entered != 1) revert Reentrancy();
        _entered = 2;
        _;
        _entered = 1;
    }

    // ---- construction -----------------------------------------------------------------------

    /// @param _poolManager The chain's PoolManager (never hardcoded).
    /// @param _owner Administrator: may pause/unpause, set the fee and the guardian.
    /// @param _guardian Pause-only circuit breaker (the Reactive callback contract); may be zero.
    /// @param basket Basket stablecoins, 2..8 distinct ERC-20s.
    /// @param decimals Each basket token's decimals (≤ 18). Passed in rather than queried so the
    /// constructor makes no external calls and the creation code can be verified on a bare chain.
    /// @param kNorms Tick planes per unit radius, strictly ascending, in (√N − 1, (N−1)/√N].
    /// @param _feePpm Swap fee on input, parts per million, ≤ 1%.
    constructor(
        IPoolManager _poolManager,
        address _owner,
        address _guardian,
        address[] memory basket,
        uint8[] memory decimals,
        uint256[] memory kNorms,
        uint24 _feePpm
    ) BaseHook(_poolManager) {
        if (_owner == address(0)) revert ZeroAddress();
        if (basket.length < 2 || basket.length > MAX_TOKENS || decimals.length != basket.length) {
            revert InvalidTokens();
        }
        if (kNorms.length == 0 || kNorms.length > MAX_LEVELS) revert InvalidLevels();
        if (_feePpm > MAX_FEE_PPM) revert FeeTooHigh();

        owner = _owner;
        guardian = _guardian;
        feePpm = _feePpm;
        n = basket.length;
        sqrtN = OrbitalMath.sqrtN(basket.length);

        for (uint256 i = 0; i < basket.length; i++) {
            address t = basket[i];
            if (t == address(0) || tokenIndex[t] != 0) revert InvalidTokens();
            uint8 dec = decimals[i];
            if (dec > 18) revert InvalidTokens();
            tokenIndex[t] = i + 1;
            _tokens.push(t);
            _scale.push(10 ** (18 - dec));
            _x.push(0);
            _feeGrowth.push(0);
        }

        uint256 kMin = sqrtN - WAD; // exclusive: the equal-price point itself
        uint256 kMax = (basket.length - 1) * WAD * WAD / sqrtN; // inclusive: full range
        uint256 prev = 0;
        for (uint256 l = 0; l < kNorms.length; l++) {
            uint256 k = kNorms[l];
            if (k <= kMin || k > kMax || k <= prev) revert InvalidLevels();
            prev = k;
            uint256 s = OrbitalMath.sNorm(k, sqrtN);
            _levels.push(
                Level({kNorm: k, sNorm: s, xMinNorm: OrbitalMath.xMinNorm(k, s, basket.length, sqrtN), radius: 0})
            );
        }

        emit OwnershipTransferred(address(0), _owner);
        emit GuardianUpdated(_guardian);
        emit FeeUpdated(_feePpm);
    }

    // ---- hook permissions -------------------------------------------------------------------

    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: true,
            afterInitialize: false,
            beforeAddLiquidity: true,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: false,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: true,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    // ---- hook callbacks ---------------------------------------------------------------------

    /// @dev Registers the pool as an Orbital pair when both currencies are basket tokens;
    /// otherwise the pool is pass-through. Refused while paused.
    function _beforeInitialize(address, PoolKey calldata key, uint160) internal override returns (bytes4) {
        if (paused) revert IsPaused();
        uint256 i0 = tokenIndex[Currency.unwrap(key.currency0)];
        uint256 i1 = tokenIndex[Currency.unwrap(key.currency1)];
        if (i0 != 0 && i1 != 0) {
            PoolId id = key.toId();
            pools[id] = PoolMeta({orbital: true, idx0: uint8(i0 - 1), idx1: uint8(i1 - 1)});
            emit OrbitalPoolRegistered(id, uint8(i0 - 1), uint8(i1 - 1));
        }
        return this.beforeInitialize.selector;
    }

    /// @dev Orbital pools keep no v4 liquidity: LPs deposit into the sphere through `deposit`.
    function _beforeAddLiquidity(address, PoolKey calldata key, ModifyLiquidityParams calldata, bytes calldata)
        internal
        view
        override
        returns (bytes4)
    {
        if (pools[key.toId()].orbital) revert LiquidityLivesInHook();
        return this.beforeAddLiquidity.selector;
    }

    function _beforeSwap(address sender, PoolKey calldata key, SwapParams calldata params, bytes calldata)
        internal
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        if (paused) revert IsPaused();
        PoolMeta memory meta = pools[key.toId()];
        if (!meta.orbital) return (this.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
        // The manager is unlocked while this hook settles a deposit, withdrawal or fee payout; a
        // swap started from inside that window (e.g. by a token's receiver hook) is refused.
        if (_entered != 1) revert Reentrancy();

        bool exactIn = params.amountSpecified < 0;
        (uint256 rawIn, uint256 rawOut) = _execute(
            sender,
            params.zeroForOne ? meta.idx0 : meta.idx1,
            params.zeroForOne ? meta.idx1 : meta.idx0,
            exactIn,
            exactIn ? uint256(-params.amountSpecified) : uint256(params.amountSpecified)
        );

        // Settle in claims: the manager keeps the tokens, the hook keeps the accounting.
        (Currency cIn, Currency cOut) =
            params.zeroForOne ? (key.currency0, key.currency1) : (key.currency1, key.currency0);
        poolManager.mint(address(this), cIn.toId(), rawIn);
        if (rawOut > 0) poolManager.burn(address(this), cOut.toId(), rawOut);

        BeforeSwapDelta delta = exactIn
            ? toBeforeSwapDelta(int128(uint128(rawIn)), -int128(uint128(rawOut)))
            : toBeforeSwapDelta(-int128(uint128(rawOut)), int128(uint128(rawIn)));
        return (this.beforeSwap.selector, delta, 0);
    }

    /// @dev Prices and commits a trade of basket token `i` for `j`; `amount` is raw units of the
    /// specified side. Fees are charged on the input and accrue to all LPs per unit radius.
    function _execute(address sender, uint8 i, uint8 j, bool exactIn, uint256 amount)
        internal
        returns (uint256 rawIn, uint256 rawOut)
    {
        uint256 feeWad;
        uint256[] memory x;
        uint256 mask;
        (rawIn, rawOut, feeWad, x, mask) = _price(i, j, exactIn, amount);
        _commit(x, mask);
        if (feeWad > 0) _feeGrowth[i] += feeWad * WAD / totalRadius;
        emit OrbitalSwap(sender, i, j, rawIn, rawOut, feeWad);
    }

    /// @dev Prices a trade of basket token `i` for `j` in raw units, fee included, and returns the
    /// resulting virtual reserves and tick mask. Shared by execution and the quote views.
    function _price(uint8 i, uint8 j, bool exactIn, uint256 amount)
        internal
        view
        returns (uint256 rawIn, uint256 rawOut, uint256 feeWad, uint256[] memory x, uint256 mask)
    {
        if (exactIn) {
            rawIn = amount;
            uint256 wadIn = rawIn * _scale[i];
            feeWad = wadIn * feePpm / FEE_DENOMINATOR;
            uint256 wadOut;
            (, wadOut, x, mask) = _simulate(i, j, wadIn - feeWad, true);
            rawOut = wadOut / _scale[j];
            x[j] += wadOut - rawOut * _scale[j]; // rounding dust stays in the pool
        } else {
            rawOut = amount;
            uint256 wadNet;
            (wadNet,, x, mask) = _simulate(i, j, rawOut * _scale[j], false);
            uint256 wadGross = OrbitalMath.ceilDiv(wadNet * FEE_DENOMINATOR, FEE_DENOMINATOR - feePpm);
            rawIn = OrbitalMath.ceilDiv(wadGross, _scale[i]);
            if (rawIn == 0) rawIn = 1;
            feeWad = rawIn * _scale[i] - wadNet;
        }
        if (rawIn > uint256(uint128(type(int128).max)) || rawOut > uint256(uint128(type(int128).max))) {
            revert AmountOverflow();
        }
    }

    // ---- liquidity --------------------------------------------------------------------------

    /// @notice Add `radius` of liquidity to tick `level`, paying at most `maxAmounts[k]` of each
    /// basket token (raw units). Tokens are pulled with `transferFrom` and parked in the PoolManager.
    /// @return amounts Raw amounts actually deposited per token.
    function deposit(uint256 levelId, uint256 radius, uint256[] calldata maxAmounts)
        external
        nonReentrant
        whenNotPaused
        returns (uint256[] memory amounts)
    {
        if (levelId >= _levels.length) revert InvalidLevel();
        if (radius < MIN_RADIUS) revert RadiusTooSmall();
        if (maxAmounts.length != n) revert LengthMismatch();
        if (totalRadius + radius > MAX_TOTAL_RADIUS) revert RadiusCapExceeded();

        // Pending fees are paid out first: that payout is an external token transfer, and every
        // state change below happens only after it has returned.
        _settleFees(levelId, msg.sender);

        (uint256[] memory virt, uint256[] memory raw, bool boundary) = _depositAmounts(_loadLevels(), levelId, radius);
        amounts = raw;
        for (uint256 k = 0; k < n; k++) {
            if (amounts[k] > maxAmounts[k]) revert SlippageExceeded();
            _x[k] += virt[k]; // the sub-unit rounding surplus stays in the manager as dust
        }

        Level storage L = _levels[levelId];
        if (L.radius == 0) {
            if (boundary) boundaryMask |= (1 << levelId);
            else boundaryMask &= ~(1 << levelId);
        }
        L.radius += radius;
        totalRadius += radius;
        positions[levelId][msg.sender] += radius;

        poolManager.unlock(abi.encode(CallbackData({action: Action.Deposit, account: msg.sender, amounts: amounts})));
        emit Deposit(msg.sender, levelId, radius, amounts);
    }

    /// @notice Remove `radius` from tick `level`; always available, even when paused.
    /// @dev A partial withdrawal must leave at least `MIN_RADIUS` in the position and in the tick.
    /// Every coin is delivered on its own: one whose transfer fails is handed over as an ERC-6909
    /// claim on the PoolManager instead (see `redeemClaims`), never blocking the others.
    /// @return amounts Raw amounts returned per token (accrued fees are paid out separately).
    function withdraw(uint256 levelId, uint256 radius, uint256[] calldata minAmounts)
        external
        nonReentrant
        returns (uint256[] memory amounts)
    {
        if (levelId >= _levels.length) revert InvalidLevel();
        if (radius == 0) revert ZeroAmount();
        if (minAmounts.length != n) revert LengthMismatch();
        uint256 held = positions[levelId][msg.sender];
        if (radius > held) revert InsufficientPosition();
        Level storage L = _levels[levelId];
        if (
            (held - radius != 0 && held - radius < MIN_RADIUS)
                || (L.radius - radius != 0 && L.radius - radius < MIN_RADIUS)
        ) {
            revert ResidualTooSmall();
        }

        _settleFees(levelId, msg.sender);

        Level[] memory lv = _loadLevels();
        (uint256[] memory virt,) = _levelVector(lv, levelId, radius, false);
        uint256 floorAll = _virtualFloor(lv);

        amounts = new uint256[](n);
        for (uint256 k = 0; k < n; k++) {
            uint256 floorK = radius * L.xMinNorm / WAD;
            uint256 real = virt[k] > floorK ? virt[k] - floorK : 0;
            uint256 available = _x[k] > floorAll ? _x[k] - floorAll : 0;
            if (real > available) real = available;
            uint256 raw = real / _scale[k];
            // Per-level floors round separately from the pool-wide floor, so the accounting can
            // overstate backing by a wei; the claim balance is what can actually be paid.
            uint256 backing = _claimBalance(k);
            if (raw > backing) raw = backing;
            if (raw < minAmounts[k]) revert SlippageExceeded();
            amounts[k] = raw;
            uint256 removed = virt[k] > _x[k] ? _x[k] : virt[k];
            _x[k] -= removed;
        }

        positions[levelId][msg.sender] = held - radius;
        L.radius -= radius;
        totalRadius -= radius;
        if (totalRadius == 0) {
            // Residual rounding dust stays with the manager; the next first deposit starts clean.
            for (uint256 k = 0; k < n; k++) {
                _x[k] = 0;
            }
        }

        poolManager.unlock(abi.encode(CallbackData({action: Action.Withdraw, account: msg.sender, amounts: amounts})));
        emit Withdraw(msg.sender, levelId, radius, amounts);
    }

    /// @notice Turn ERC-6909 claims on the PoolManager (as delivered by `withdraw`/`collectFees`
    /// for a coin that could not be transferred at the time) back into `token`, sent to `to`.
    /// The caller must first approve this hook on the PoolManager (`setOperator` or `approve`).
    function redeemClaims(address token, uint256 amount, address to) external nonReentrant {
        uint256 idx = tokenIndex[token];
        if (idx == 0) revert InvalidTokens();
        if (amount == 0) revert ZeroAmount();
        if (to == address(0)) revert ZeroAddress();
        poolManager.transferFrom(msg.sender, address(this), uint256(uint160(token)), amount);
        uint256[] memory amounts = new uint256[](n);
        amounts[idx - 1] = amount;
        poolManager.unlock(abi.encode(CallbackData({action: Action.Redeem, account: to, amounts: amounts})));
        emit ClaimsRedeemed(msg.sender, token, amount, to);
    }

    /// @notice Pay out the swap fees accrued to the caller's position in `level`.
    function collectFees(uint256 levelId) external nonReentrant returns (uint256[] memory amounts) {
        if (levelId >= _levels.length) revert InvalidLevel();
        amounts = _settleFees(levelId, msg.sender);
    }

    /// @dev Pays pending fees for (level, lp) and resets its debt. Safe to call when radius is 0.
    function _settleFees(uint256 levelId, address lp) internal returns (uint256[] memory amounts) {
        bool any;
        (amounts, any) = _owed(levelId, lp);
        for (uint256 k = 0; k < n; k++) {
            _feeDebt[levelId][lp][k] = _feeGrowth[k];
        }
        if (any) {
            poolManager.unlock(abi.encode(CallbackData({action: Action.Withdraw, account: lp, amounts: amounts})));
            emit FeesCollected(lp, levelId, amounts);
        }
    }

    /// @dev Fees owed to (level, lp) in raw units, capped at what the hook's claims can pay.
    function _owed(uint256 levelId, address lp) internal view returns (uint256[] memory amounts, bool any) {
        amounts = new uint256[](n);
        uint256 radius = positions[levelId][lp];
        if (radius == 0) return (amounts, false);
        for (uint256 k = 0; k < n; k++) {
            uint256 growth = _feeGrowth[k];
            uint256 debt = _feeDebt[levelId][lp][k];
            if (growth > debt) {
                uint256 owed = radius * (growth - debt) / WAD / _scale[k];
                uint256 backing = _claimBalance(k);
                amounts[k] = owed > backing ? backing : owed;
                if (amounts[k] > 0) any = true;
            }
        }
    }

    /// @inheritdoc IUnlockCallback
    function unlockCallback(bytes calldata rawData) external onlyPoolManager returns (bytes memory) {
        CallbackData memory data = abi.decode(rawData, (CallbackData));
        for (uint256 k = 0; k < n; k++) {
            uint256 amount = data.amounts[k];
            if (amount == 0) continue;
            Currency c = Currency.wrap(_tokens[k]);
            if (data.action == Action.Deposit) {
                poolManager.sync(c);
                _safeTransferFrom(_tokens[k], data.account, address(poolManager), amount);
                poolManager.settle();
                poolManager.mint(address(this), c.toId(), amount);
            } else {
                // `take` moves the ERC-20 out of the manager and debits this hook; the burn pays
                // the debit. On a withdrawal or fee payout a coin whose transfer reverts (issuer
                // pause, blocklist) must not strand the others: its claim is handed to the account
                // instead. A redeem has no fallback.
                try poolManager.take(c, data.account, amount) {
                    poolManager.burn(address(this), c.toId(), amount);
                } catch {
                    if (data.action == Action.Redeem) revert TransferFailed();
                    poolManager.transfer(data.account, c.toId(), amount);
                    emit ClaimsDelivered(data.account, _tokens[k], amount);
                }
            }
        }
        return "";
    }

    /// @dev ERC-6909 claims of basket token `k` this hook holds on the manager.
    function _claimBalance(uint256 k) internal view returns (uint256) {
        return poolManager.balanceOf(address(this), uint256(uint160(_tokens[k])));
    }

    // ---- circuit breaker & admin ------------------------------------------------------------

    /// @notice Fail-safe used by the Reactive depeg callback. Idempotent; can only pause.
    function guardianPause() external {
        if (msg.sender != guardian) revert NotGuardian();
        if (!paused) {
            paused = true;
            emit Paused(msg.sender, true);
        }
    }

    function pause() external onlyOwner {
        if (!paused) {
            paused = true;
            emit Paused(msg.sender, false);
        }
    }

    /// @notice Resuming is deliberately owner-only: a human reviews the depeg before trading resumes.
    function unpause() external onlyOwner {
        paused = false;
        emit Unpaused(msg.sender);
    }

    function setGuardian(address _guardian) external onlyOwner {
        guardian = _guardian;
        emit GuardianUpdated(_guardian);
    }

    function setFee(uint24 _feePpm) external onlyOwner {
        if (_feePpm > MAX_FEE_PPM) revert FeeTooHigh();
        feePpm = _feePpm;
        emit FeeUpdated(_feePpm);
    }

    function transferOwnership(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert ZeroAddress();
        emit OwnershipTransferred(owner, newOwner);
        owner = newOwner;
    }

    // ---- views ------------------------------------------------------------------------------

    function tokens() external view returns (address[] memory) {
        return _tokens;
    }

    function scale(uint256 k) external view returns (uint256) {
        return _scale[k];
    }

    function levelCount() external view returns (uint256) {
        return _levels.length;
    }

    function level(uint256 l) external view returns (Level memory) {
        return _levels[l];
    }

    /// @notice Virtual reserves on the sphere (WAD).
    function reserves() external view returns (uint256[] memory) {
        return _x;
    }

    /// @notice Reserves actually backing the pool (WAD): virtual minus the concentrated floor.
    function realReserves() external view returns (uint256[] memory out) {
        uint256 floorAll = _virtualFloor(_loadLevels());
        out = new uint256[](n);
        for (uint256 k = 0; k < n; k++) {
            out[k] = _x[k] > floorAll ? _x[k] - floorAll : 0;
        }
    }

    /// @notice Virtual reserve vector attributable to `l` for its whole radius (WAD).
    function levelReserves(uint256 l) external view returns (uint256[] memory) {
        Level[] memory lv = _loadLevels();
        if (lv[l].radius == 0) return new uint256[](n);
        (uint256[] memory v,) = _levelVector(lv, l, lv[l].radius, false);
        return v;
    }

    /// @notice Consolidated interior radius, boundary plane and boundary circle radius.
    function consolidated() external view returns (uint256 r, uint256 kb, uint256 sb) {
        OrbitalMath.Consolidated memory c = _consolidate(_loadLevels(), boundaryMask);
        return (c.r, c.kb, c.sb);
    }

    /// @notice Normalised interior position (WAD). Ticks with kNorm below it are boundary. With
    /// only pinned liquidity left this is the highest pinned plane; with no liquidity, `int256.max`.
    function alphaIntNorm() external view returns (int256) {
        if (totalRadius == 0) return type(int256).max;
        Level[] memory lv = _loadLevels();
        (uint256 s,) = _sums(_x);
        return _position(lv, boundaryMask, s, _consolidate(lv, boundaryMask));
    }

    /// @notice Value of the torus invariant at the current point (≈0 on the surface).
    function invariant() external view returns (int256) {
        (uint256 s, uint256 q) = _sums(_x);
        return OrbitalMath.invariant(s, q, n, sqrtN, _consolidate(_loadLevels(), boundaryMask));
    }

    /// @notice Raw output for a raw input, fee included.
    function quoteExactInput(address tokenIn, address tokenOut, uint256 rawIn) external view returns (uint256 rawOut) {
        (uint8 i, uint8 j) = _indices(tokenIn, tokenOut);
        (, rawOut,,,) = _price(i, j, true, rawIn);
    }

    /// @notice Raw input needed for a raw output, fee included.
    function quoteExactOutput(address tokenIn, address tokenOut, uint256 rawOut) external view returns (uint256 rawIn) {
        (uint8 i, uint8 j) = _indices(tokenIn, tokenOut);
        (rawIn,,,,) = _price(i, j, false, rawOut);
    }

    /// @notice Raw deposit required per token to add `radius` at `l` right now.
    function previewDeposit(uint256 l, uint256 radius) external view returns (uint256[] memory amounts) {
        (, amounts,) = _depositAmounts(_loadLevels(), l, radius);
    }

    /// @notice Fees claimable right now by `lp` in `l`, raw units.
    function pendingFees(uint256 l, address lp) external view returns (uint256[] memory amounts) {
        (amounts,) = _owed(l, lp);
    }

    /// @dev Virtual vector, raw deposit per token (virtual minus the tick's floor, rounded up) and
    /// boundary status for adding `radius` at `l` now.
    function _depositAmounts(Level[] memory lv, uint256 l, uint256 radius)
        internal
        view
        returns (uint256[] memory virt, uint256[] memory amounts, bool boundary)
    {
        (virt, boundary) = _levelVector(lv, l, radius, true);
        amounts = new uint256[](n);
        uint256 floorK = radius * lv[l].xMinNorm / WAD;
        for (uint256 k = 0; k < n; k++) {
            amounts[k] = OrbitalMath.ceilDiv(virt[k] > floorK ? virt[k] - floorK : 0, _scale[k]);
        }
    }

    // ---- internal geometry ------------------------------------------------------------------

    function _indices(address tokenIn, address tokenOut) internal view returns (uint8 i, uint8 j) {
        uint256 a = tokenIndex[tokenIn];
        uint256 b = tokenIndex[tokenOut];
        if (a == 0 || b == 0 || a == b) revert InvalidTokens();
        return (uint8(a - 1), uint8(b - 1));
    }

    function _loadLevels() internal view returns (Level[] memory lv) {
        uint256 len = _levels.length;
        lv = new Level[](len);
        for (uint256 l = 0; l < len; l++) {
            lv[l] = _levels[l];
        }
    }

    function _consolidate(Level[] memory lv, uint256 mask) internal pure returns (OrbitalMath.Consolidated memory c) {
        for (uint256 l = 0; l < lv.length; l++) {
            uint256 r = lv[l].radius;
            if (r == 0) continue;
            if (mask & (1 << l) != 0) {
                c.kb += lv[l].kNorm * r / WAD;
                c.sb += lv[l].sNorm * r / WAD;
            } else {
                c.r += r;
            }
        }
    }

    function _virtualFloor(Level[] memory lv) internal pure returns (uint256 f) {
        for (uint256 l = 0; l < lv.length; l++) {
            f += lv[l].xMinNorm * lv[l].radius / WAD;
        }
    }

    function _sums(uint256[] memory x) internal pure returns (uint256 s, uint256 q) {
        for (uint256 k = 0; k < x.length; k++) {
            s += x[k];
            q += x[k] * x[k];
        }
    }

    /// @dev Normalised interior position under `mask`. When no interior liquidity is left the
    /// interior sits (by definition) on the plane of the highest pinned tick: that is the only
    /// position consistent with every pinned tick staying pinned.
    function _position(Level[] memory lv, uint256 mask, uint256 s, OrbitalMath.Consolidated memory c)
        internal
        view
        returns (int256)
    {
        if (c.r > 0) return OrbitalMath.alphaIntNorm(s, sqrtN, c);
        (bool found, uint256 top) = _topPinned(lv, mask);
        return found ? int256(lv[top].kNorm) : type(int256).max;
    }

    /// @dev Highest-plane pinned tick holding liquidity.
    function _topPinned(Level[] memory lv, uint256 mask) internal pure returns (bool found, uint256 top) {
        for (uint256 l = 0; l < lv.length; l++) {
            if (lv[l].radius == 0 || mask & (1 << l) == 0) continue;
            found = true;
            top = l; // levels are ascending in kNorm
        }
    }

    /// @dev Virtual reserve vector for `radius` of tick `l` at the current point. For an empty
    /// level the tick's status is derived from the interior position.
    ///
    /// A deposit (`incoming`) is priced on the tick's own surface: a boundary tick on its circle,
    /// an interior tick on the sphere through the interior's current direction. A state point that
    /// sits off the torus by some dust is therefore never copied in proportion to the new radius.
    /// A withdrawal takes the tick's proportional share of what the interior actually holds, so it
    /// can never pay out more than the pool's accounting backs.
    function _levelVector(Level[] memory lv, uint256 l, uint256 radius, bool incoming)
        internal
        view
        returns (uint256[] memory v, bool boundary)
    {
        if (totalRadius == 0) {
            // First deposit opens the pool at the equal-price point, xᵢ = r(1 − 1/√N).
            return (_equalPoint(radius), false);
        }

        OrbitalMath.Consolidated memory c = _consolidate(lv, boundaryMask);
        (uint256 s, uint256 q) = _sums(_x);
        uint256 w = OrbitalMath.wNorm(s, q, n);

        if (lv[l].radius > 0) {
            boundary = boundaryMask & (1 << l) != 0;
        } else {
            boundary = _position(lv, boundaryMask, s, c) > int256(lv[l].kNorm);
        }

        if (boundary) return (_circlePoint(lv[l].kNorm, lv[l].sNorm, s, w, radius), true);
        if (c.r == 0) {
            // Only pinned liquidity is left: a new interior opens on the highest pinned plane,
            // where the pinned ticks and the fresh sphere share one point and one direction.
            if (!incoming) revert NoInteriorLiquidity();
            (, uint256 top) = _topPinned(lv, boundaryMask);
            return (_circlePoint(lv[top].kNorm, lv[top].sNorm, s, w, radius), false);
        }
        return (_interiorPoint(c, s, w, radius, incoming), false);
    }

    /// @dev xᵢ = r(1 − 1/√N) for every coin, rounded up by at most ~r/N·1e-18 so the opening point
    /// is never outside the sphere: a later on-sphere deposit followed by a proportional withdrawal
    /// can then never return more than was put in. (The sub-raw-unit excess this leaves is dust.)
    function _equalPoint(uint256 radius) internal view returns (uint256[] memory v) {
        v = new uint256[](n);
        uint256 each = radius - radius * WAD / (sqrtN + 1); // sqrtN is floored, so this is ≥ exact
        for (uint256 k = 0; k < n; k++) {
            v[k] = each;
        }
    }

    /// @dev Point of a tick of `radius` pinned to plane `kNorm`: x = k·v/√N·… + s·ŵ, with ŵ the
    /// pool's current direction. Each coordinate rounds down (pool-favoured) at wei precision.
    function _circlePoint(uint256 kNorm, uint256 sNorm, uint256 s, uint256 w, uint256 radius)
        internal
        view
        returns (uint256[] memory v)
    {
        v = new uint256[](n);
        int256 along = int256(kNorm * radius / sqrtN); // k·r/√N per coin
        int256 sr = int256(sNorm * radius / WAD);
        for (uint256 k = 0; k < n; k++) {
            int256 val = along;
            if (w != 0) val += _floorDiv((int256(_x[k]) - int256(s / n)) * sr, int256(w));
            v[k] = val > 0 ? uint256(val) : 0;
        }
    }

    /// @dev Point of an interior tick of `radius`. `projected`: the current interior reserve vector
    /// (x − x_bound) projected onto the sphere of radius r_int, then scaled to `radius`, so that if
    /// the pool's point sits inside or outside the surface by some dust the new position still lands
    /// exactly on its own sphere. Otherwise the proportional share (x − x_bound)·radius/r_int.
    function _interiorPoint(OrbitalMath.Consolidated memory c, uint256 s, uint256 w, uint256 radius, bool projected)
        internal
        view
        returns (uint256[] memory v)
    {
        int256[] memory u = new int256[](n); // interior reserve (minus the sphere centre if projected)
        uint256 uu;
        for (uint256 k = 0; k < n; k++) {
            int256 xBound = int256(c.kb * WAD / sqrtN);
            if (w != 0) xBound += _floorDiv((int256(_x[k]) - int256(s / n)) * int256(c.sb), int256(w));
            u[k] = int256(_x[k]) - xBound;
            if (projected) {
                u[k] -= int256(c.r);
                uu += uint256(u[k] * u[k]);
            }
        }
        v = new uint256[](n);
        if (!projected) {
            for (uint256 k = 0; k < n; k++) {
                v[k] = u[k] > 0 ? uint256(u[k]) * radius / c.r : 0;
            }
            return v;
        }
        uint256 uNorm = OrbitalMath.sqrt(uu);
        if (uNorm == 0) return _equalPoint(radius);
        for (uint256 k = 0; k < n; k++) {
            int256 val = int256(radius) + _floorDiv(u[k] * int256(radius), int256(uNorm));
            v[k] = val > 0 ? uint256(val) : 0;
        }
    }

    function _floorDiv(int256 a, int256 b) internal pure returns (int256 q) {
        q = a / b;
        if ((a % b != 0) && ((a < 0) != (b < 0))) q -= 1;
    }

    struct Trade {
        uint8 i;
        uint8 j;
        bool exactIn;
        uint256 remaining;
        uint256 amountIn;
        uint256 amountOut;
        uint256 mask;
        uint256[] x;
        Level[] lv;
    }

    /// @dev Core trade engine on memory copies. Splits the trade at every tick boundary it crosses.
    function _simulate(uint8 i, uint8 j, uint256 amount, bool exactIn)
        internal
        view
        returns (uint256 amountIn, uint256 amountOut, uint256[] memory x, uint256 mask)
    {
        if (amount == 0) revert ZeroAmount();
        Trade memory t = Trade({
            i: i,
            j: j,
            exactIn: exactIn,
            remaining: amount,
            amountIn: 0,
            amountOut: 0,
            mask: boundaryMask,
            x: _x,
            lv: _loadLevels()
        });

        // Each tick can leave the interior at most once (while α falls) and rejoin it at most once
        // (while α rises) per trade, plus one final segment.
        for (uint256 iter = 0; iter <= 2 * t.lv.length + 1; iter++) {
            if (_step(t)) return (t.amountIn, t.amountOut, t.x, t.mask);
        }
        revert TooManyCrossings();
    }

    /// @dev One segment of a trade under the current consolidation. Returns true when the trade
    /// is complete; false when it stopped at a tick boundary and flipped that tick.
    ///
    /// α falls while xᵢ < xⱼ (the trade heads back towards the peg) and rises afterwards, so a
    /// segment is examined in that order: first the pinned tick nearest below the interior, which
    /// must rejoin the interior where the falling path meets its plane; then the interior tick
    /// nearest above, which pins where the rising path meets its plane. A tick whose recorded
    /// status already disagrees with the interior position (one-unit rounding after a deposit or
    /// withdrawal, or a state left exactly on a plane) is flipped where the trade stands.
    function _step(Trade memory t) internal view returns (bool done) {
        OrbitalMath.Consolidated memory c = _consolidate(t.lv, t.mask);
        if (c.r == 0) revert NoInteriorLiquidity();
        OrbitalMath.Pair memory p = _pair(t);
        uint256 realJ = _realOut(t);

        // (a) Towards the peg (α falling while xᵢ < xⱼ): the highest pinned tick is the first
        //     whose plane the path can meet, and it rejoins the interior there.
        if (p.xi < p.xj) {
            (bool found, uint256 l) = _topPinned(t.lv, t.mask);
            if (found && _tryFlip(t, p, c, realJ, l, false)) return false;
        }

        (uint256 dIn, uint256 dOut) = _solveSegment(t, p, c, realJ);

        // (b) Away from the peg: the lowest interior tick whose plane lies at or below the
        //     segment's end pins where the rising path meets it.
        {
            (bool found, uint256 l) =
                _lowestInteriorBelow(t.lv, t.mask, OrbitalMath.alphaIntNorm(p.s + dIn - dOut, sqrtN, c));
            if (found && _tryFlip(t, p, c, realJ, l, true)) return false;
        }

        _apply(t, dIn, dOut);
        _checkFinal(t.x, t.i, c);
        return true;
    }

    function _pair(Trade memory t) internal pure returns (OrbitalMath.Pair memory p) {
        (uint256 s, uint256 q) = _sums(t.x);
        return OrbitalMath.Pair({xi: t.x[t.i], xj: t.x[t.j], s: s, q: q});
    }

    /// @dev Real (deposited) reserve of the output token: what a trade may take at most.
    function _realOut(Trade memory t) internal pure returns (uint256) {
        uint256 floorAll = _virtualFloor(t.lv);
        return t.x[t.j] > floorAll ? t.x[t.j] - floorAll : 0;
    }

    /// @dev Prices the whole remaining trade under consolidation `c`.
    function _solveSegment(Trade memory t, OrbitalMath.Pair memory p, OrbitalMath.Consolidated memory c, uint256 realJ)
        internal
        view
        returns (uint256 dIn, uint256 dOut)
    {
        if (t.exactIn) {
            dIn = t.remaining;
            dOut = OrbitalMath.solveOut(p, dIn, realJ, n, sqrtN, c);
        } else {
            if (t.remaining > realJ) revert OrbitalMath.InsufficientLiquidity();
            dOut = t.remaining;
            dIn = OrbitalMath.solveIn(p, dOut, c.r + c.kb + c.sb, n, sqrtN, c);
        }
    }

    /// @dev Flips tick `l` where the path meets its plane within the trade: `pin = false` unpins it
    /// on the j-heavy image (met while α falls), `pin = true` pins it on the i-heavy image (met
    /// while α rises). A tick whose plane the interior already sits on, or beyond, within
    /// `POSITION_TOLERANCE` is flipped where the trade stands (pinning only while rising). A plane
    /// step counts only when it makes progress and ends short of the trade. Returns true if flipped.
    function _tryFlip(
        Trade memory t,
        OrbitalMath.Pair memory p,
        OrbitalMath.Consolidated memory c,
        uint256 realJ,
        uint256 l,
        bool pin
    ) internal view returns (bool) {
        int256 gap = int256(t.lv[l].kNorm) - OrbitalMath.alphaIntNorm(p.s, sqrtN, c); // plane − position
        bool atPlane = pin ? (p.xi >= p.xj && gap <= POSITION_TOLERANCE) : (gap + POSITION_TOLERANCE >= 0);
        if (!atPlane) {
            (bool ok, uint256 tIn, uint256 d1) = _toPlane(t.lv[l], p, c, pin);
            if (!ok || tIn == 0 || (t.exactIn ? tIn >= t.remaining : d1 >= t.remaining)) return false;
            if (d1 > realJ) revert OrbitalMath.InsufficientLiquidity();
            _apply(t, tIn, d1);
        }
        t.mask = pin ? t.mask | (1 << l) : t.mask & ~(1 << l);
        return true;
    }

    /// @dev Lowest interior tick (holding liquidity) whose plane is at or below `aAfter`.
    function _lowestInteriorBelow(Level[] memory lv, uint256 mask, int256 aAfter)
        internal
        pure
        returns (bool found, uint256 best)
    {
        for (uint256 l = 0; l < lv.length; l++) {
            if (lv[l].radius == 0 || mask & (1 << l) != 0) continue;
            if (int256(lv[l].kNorm) <= aAfter) return (true, l); // ascending in kNorm
        }
    }

    /// @dev Input/output that lands exactly on tick `L`'s plane from `p` under consolidation `c`,
    /// on the j-heavy image (`iHeavy = false`, met while α falls) or the i-heavy one (met while it
    /// rises). `ok` is false when the path does not reach that image ahead of `p`.
    function _toPlane(Level memory L, OrbitalMath.Pair memory p, OrbitalMath.Consolidated memory c, bool iHeavy)
        internal
        view
        returns (bool ok, uint256 tIn, uint256 dOut)
    {
        uint256 alphaT = L.kNorm * c.r / WAD + c.kb;
        uint256 sT = alphaT * sqrtN / WAD;
        uint256 wT = c.sb + c.r * L.sNorm / WAD;
        uint256 qT = wT * wT + sT * sT / n;
        return OrbitalMath.tryPlaneStep(p, sT, qT, iHeavy);
    }

    function _apply(Trade memory t, uint256 dIn, uint256 dOut) internal pure {
        t.x[t.i] += dIn;
        t.x[t.j] -= dOut;
        t.amountIn += dIn;
        t.amountOut += dOut;
        t.remaining -= t.exactIn ? dIn : dOut;
    }

    /// @dev End-of-trade checks. (1) On every valid state the pool's ‖w‖ covers the pinned ticks'
    /// circle radii (the interior contributes a non-negative multiple of the shared direction); a
    /// trade ending with ‖w‖ below s_bound has gone through the interior's equal-price point with a
    /// tick still pinned, which the crossing logic prevents — refuse it rather than commit an
    /// inverted state. (2) A trade may not push a token's interior reserve past the sphere's pole
    /// (price ≤ 0).
    function _checkFinal(uint256[] memory x, uint8 i, OrbitalMath.Consolidated memory c) internal view {
        (uint256 s, uint256 q) = _sums(x);
        uint256 w = OrbitalMath.wNorm(s, q, n);
        if (w < c.sb) revert BoundaryInverted();
        int256 xBound = int256(c.kb * WAD / sqrtN);
        if (w != 0) xBound += int256(c.sb) * (int256(x[i]) - int256(s / n)) / int256(w);
        if (int256(x[i]) - xBound > int256(c.r)) revert SwapTooLarge();
    }

    function _commit(uint256[] memory x, uint256 mask) internal {
        for (uint256 k = 0; k < n; k++) {
            _x[k] = x[k];
        }
        uint256 old = boundaryMask;
        if (mask != old) {
            boundaryMask = mask;
            uint256 changed = mask ^ old;
            for (uint256 l = 0; l < _levels.length; l++) {
                if (changed & (1 << l) != 0) emit LevelCrossed(l, mask & (1 << l) != 0);
            }
        }
    }

    function _safeTransferFrom(address token, address from, address to, uint256 amount) internal {
        (bool ok, bytes memory ret) = token.call(abi.encodeWithSelector(0x23b872dd, from, to, amount)); // transferFrom
        if (!ok || (ret.length != 0 && !abi.decode(ret, (bool))) || token.code.length == 0) revert TransferFailed();
    }
}
