// SPDX-License-Identifier: MIT

pragma solidity ^0.8.18;

import {DeployDSC} from "../../script/DeployDSC.s.sol";
import {DSCEngine} from "../../src/DSCEngine.sol";
import {DecentralizedStableCoin} from "../../src/DecentralizedStableCoin.sol";
import {HelperConfig} from "../../script/HelperConfig.s.sol";
import {Test, console} from "forge-std/Test.sol";
import {ERC20Mock} from "../mocks/ERC20Mock.sol";
import {MockV3Aggregator} from "../mocks/MockV3Aggregator.sol";

contract DSCEngineTest is Test {
    address public USER = makeAddr("user");
    uint256 public constant AMOUNT_COLLATERAL = 10 ether;
    uint256 public constant STARTING_ERC20_BALANCE = 10 ether;
    DeployDSC deployer;
    DecentralizedStableCoin dsc;
    DSCEngine dsce;
    HelperConfig config;
    address weth;
    address ethUsdPriceFeed;
    address btcUsdPriceFeed;

    function setUp() public {
        deployer = new DeployDSC();
        (dsc, dsce, config) = deployer.run();
        (ethUsdPriceFeed, btcUsdPriceFeed, weth,,) = config.activeNetworkConfig();

        ERC20Mock(weth).mint(USER, STARTING_ERC20_BALANCE);
    }

    /*//////////////////////////////////////////////////////////////
                              CONSTRUCTOR TESTS
    //////////////////////////////////////////////////////////////*/
    address[] public tokenAddresses;
    address[] public priceFeedAddresses;

    function testRevertsIfTokenLengthDoesntMatchPriceFeeds() public {
        tokenAddresses.push(weth);
        priceFeedAddresses.push(ethUsdPriceFeed);
        priceFeedAddresses.push(btcUsdPriceFeed);

        vm.expectRevert(DSCEngine.DSCEngine__TokenAddressAndPriceFeedAddressLengthMustBeSameLength.selector);
        new DSCEngine(tokenAddresses, priceFeedAddresses, address(dsc));
    }

    function testConstructorSetsPriceFeedsCorrectly() public {
        tokenAddresses.push(weth);
        priceFeedAddresses.push(ethUsdPriceFeed);

        DSCEngine engine = new DSCEngine(tokenAddresses, priceFeedAddresses, address(dsc));

        address priceFeed = engine.getPriceFeed(weth);
        assertEq(priceFeed, ethUsdPriceFeed);
    }

    function testConstructorAddsCollateralTokens() public {
        tokenAddresses.push(weth);
        priceFeedAddresses.push(ethUsdPriceFeed);

        DSCEngine engine = new DSCEngine(tokenAddresses, priceFeedAddresses, address(dsc));

        address collateralToken = engine.getCollateralToken(0);
        assertEq(collateralToken, weth);
    }

    function testConstructorSetsDSCAddress() public {
        tokenAddresses.push(weth);
        priceFeedAddresses.push(ethUsdPriceFeed);

        DSCEngine engine = new DSCEngine(tokenAddresses, priceFeedAddresses, address(dsc));

        address engineDsc = address(engine.getDsc());
        assertEq(engineDsc, address(dsc));
    }

    /*//////////////////////////////////////////////////////////////
                              PRICE TESTS
    //////////////////////////////////////////////////////////////*/
    function testGetUsdValue() public {
        // 15e18 * 2,000/ETH = 30,000e18
        uint256 ethAmount = 15e18;
        uint256 expectedUsd = 30000e18;
        uint256 actualUsd = dsce.getUsdValue(weth, ethAmount);
        assertEq(expectedUsd, actualUsd);
    }

    function testGetTokenAmountFromUsd() public {
        uint256 usdAmount = 100 ether;
        // $2,000 / ETH, so 100 / 2000 = 0.05 ETH
        uint256 expectedWeth = 0.05 ether;
        uint256 actualWeth = dsce.getTokenAmountFromUsd(weth, usdAmount);

        assertEq(expectedWeth, actualWeth);
    }

    /*//////////////////////////////////////////////////////////////
                        DEPOSITCOLLATERAL TESTS
    //////////////////////////////////////////////////////////////*/
    function testRevertsIfCollateralZero() public {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL);

        vm.expectRevert(DSCEngine.DSCEngine__NeedsMoreThanZero.selector);
        dsce.depositCollateral(weth, 0);
        vm.stopPrank();
    }

    function testRevertsWithUnapprovedCollateral() public {
        ERC20Mock ranToken = new ERC20Mock("RAN", "RAN", USER, AMOUNT_COLLATERAL);
        vm.startPrank(USER);
        vm.expectRevert(DSCEngine.DSCEngine__NotAllowedToken.selector);
        dsce.depositCollateral(address(ranToken), AMOUNT_COLLATERAL);
        vm.stopPrank();
    }

    modifier depositedCollateral() {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL);
        dsce.depositCollateral(weth, AMOUNT_COLLATERAL);
        vm.stopPrank();
        _;
    }

    function testCanDepositCollateralAndGetAccountInfo() public depositedCollateral {
        (uint256 totalDscMinted, uint256 collateralValueInUsd) = dsce.getAccountInformation(USER);

        uint256 expectedTotalDscMinted = 0;
        uint256 expectedDepositAmount = dsce.getTokenAmountFromUsd(weth, collateralValueInUsd);
        assertEq(expectedTotalDscMinted, totalDscMinted);
        assertEq(AMOUNT_COLLATERAL, expectedDepositAmount);
    }

    function testDepositCollateralAndMintDscWorks() public {
        uint256 mintAmount = 100 ether;

        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL); // 10 ether

        dsce.depositCollateralAndMintDsc(weth, AMOUNT_COLLATERAL, mintAmount);
        vm.stopPrank();

        (uint256 dscMinted, uint256 collateralValueUsd) = dsce.getAccountInformation(USER);

        assertEq(dscMinted, mintAmount);
        assertGt(collateralValueUsd, 0);
    }

    function testMintDscRevertsIfHealthFactorBroken() public depositedCollateral {
        vm.startPrank(USER);

        // collateral = $20,000
        // threshold 50% → max mint = $10,000
        uint256 tooMuchMint = 20_000 ether;

        vm.expectRevert();
        dsce.mintDsc(tooMuchMint);

        vm.stopPrank();
    }

    function testCanMintDsc() public depositedCollateral {
        uint256 mintAmount = 100 ether;

        vm.startPrank(USER);
        dsce.mintDsc(mintAmount);
        vm.stopPrank();

        uint256 userDscBalance = dsc.balanceOf(USER);
        assertEq(userDscBalance, mintAmount);
    }

    function testRedeemCollateralRevertsIfHealthFactorBroken() public depositedCollateral {
        vm.startPrank(USER);
        dsce.mintDsc(100 ether);

        vm.expectRevert(abi.encodeWithSelector(DSCEngine.DSCEngine__BreaksHealthFactor.selector, 0));
        dsce.redeemCollateral(weth, AMOUNT_COLLATERAL);

        vm.stopPrank();
    }

    function testCanRedeemCollateral() public depositedCollateral {
        vm.startPrank(USER);
        dsce.redeemCollateral(weth, AMOUNT_COLLATERAL);
        vm.stopPrank();

        uint256 userBalance = ERC20Mock(weth).balanceOf(USER);
        assertEq(userBalance, STARTING_ERC20_BALANCE);
    }

    function testRedeemCollateralForDscWorks() public depositedCollateral {
        uint256 mintAmount = 100 ether;

        vm.startPrank(USER);
        dsce.mintDsc(mintAmount);

        dsc.approve(address(dsce), mintAmount);
        dsce.redeemCollateralForDsc(weth, AMOUNT_COLLATERAL, mintAmount);
        vm.stopPrank();

        uint256 dscBalance = dsc.balanceOf(USER);
        uint256 wethBalance = ERC20Mock(weth).balanceOf(USER);

        assertEq(dscBalance, 0);
        assertEq(wethBalance, STARTING_ERC20_BALANCE);
    }

    function testBurnDscReducesMintedAmount() public depositedCollateral {
        uint256 mintAmount = 100 ether;

        vm.startPrank(USER);
        dsce.mintDsc(mintAmount);

        dsc.approve(address(dsce), mintAmount);
        dsce.burnDSC(mintAmount);
        vm.stopPrank();

        (uint256 minted,) = dsce.getAccountInformation(USER);
        assertEq(minted, 0);
    }

    function testLiquidateRevertsIfHealthFactorOk() public depositedCollateral {
        vm.startPrank(USER);
        dsce.mintDsc(100 ether);
        vm.stopPrank();

        vm.startPrank(address(1));
        vm.expectRevert(DSCEngine.DSCEngine__HealthFactorOk.selector);
        dsce.liquidate(weth, USER, 10 ether);
        vm.stopPrank();
    }
}
