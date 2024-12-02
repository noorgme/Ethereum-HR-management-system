// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.24;

import {Test, console, stdStorage, StdStorage} from "../lib/forge-std/src/Test.sol";
import {HumanResources, IHumanResources} from "../src/HumanResources.sol";
import "../src/utils/ReentrancyGuard.sol";
import "../src/interfaces/IERC20.sol";
import {AggregatorV3Interface} from "../src/interfaces/AggregatorV3Interface.sol";


contract HumanResourcesTest is Test {
    using stdStorage for StdStorage;

    address internal constant _WETH =
        0x4200000000000000000000000000000000000006;
    address internal constant _USDC =
        0x0b2C639c533813f4Aa9D7837CAf62653d097Ff85;
    AggregatorV3Interface internal constant _ETH_USD_FEED =
        AggregatorV3Interface(0x13e3Ee699D1909E989722E753853AE30b17e08c5);

    HumanResources public humanResources;

    address public hrManager;

    address public alice = makeAddr("alice");
    address public bob = makeAddr("bob");
    address public charlie = makeAddr("charlie");

    uint256 public aliceSalary = 2100e18;
    uint256 public bobSalary = 700e18;
    uint256 public charlieSalary = 3000e18;

    uint256 ethPrice;

    function setUp() public {
        vm.createSelectFork("https://mainnet.optimism.io");
        humanResources = HumanResources(payable(0x2BAC39eA951db351d494A70e3c77859CeFee80A4));

        // Deploy contract dynamically instead of relying on HR_CONTRACT
        // humanResources = new HumanResources(
        //     0x0b2C639c533813f4Aa9D7837CAf62653d097Ff85, // USDC Address
        //     0x4200000000000000000000000000000000000006, // WETH Address
        //     0x13e3Ee699D1909E989722E753853AE30b17e08c5, // Chainlink ETH/USD Price Feed
        //     0xE592427A0AEce92De3Edee1F18E0157C05861564  // Uniswap Router
        // );
        
        (, int256 answer, , , ) = _ETH_USD_FEED.latestRoundData();
        uint256 feedDecimals = _ETH_USD_FEED.decimals();
        ethPrice = uint256(answer) * 10 ** (18 - feedDecimals);
        hrManager = humanResources.hrManager();
    }

        /// @notice This error is raised if a user tries to call a function they are not authorized to call
    error NotAuthorized();

    /// @notice This error is raised if a user tries to register an employee that is already registered
    error EmployeeAlreadyRegistered();

    /// @notice This error is raised if a user tries to terminate an employee that is not registered
    error EmployeeNotRegistered();

    /// @notice This event is emitted when an employee is registered
    event EmployeeRegistered(address indexed employee, uint256 weeklyUsdSalary);

    /// @notice This event is emitted when an employee is terminated
    event EmployeeTerminated(address indexed employee);

    /// @notice This event is emitted when an employee withdraws their salary
    /// @param amount must be the amount in the currency the employee prefers (USDC or ETH) scaled correctly
    event SalaryWithdrawn(address indexed employee, bool isEth, uint256 amount);

    /// @notice This event is emitted when an employee switches the currency in which they receive the salary
    event CurrencySwitched(address indexed employee, bool isEth);


    // --- My Test Suite --- //

    // 1. Access Control Tests

    function test_onlyHrManagerCanRegister() public {
        // Attempt to register employee as non-HR manager
        vm.prank(alice);
        vm.expectRevert(NotAuthorized.selector);
        humanResources.registerEmployee(alice, aliceSalary);
    }

    function test_onlyHrManagerCanTerminate() public {
        _registerEmployee(alice, aliceSalary);

        // Attempt to terminate employee as non-HR manager
        vm.prank(alice);
        vm.expectRevert(NotAuthorized.selector);
        humanResources.terminateEmployee(alice);
    }


    // 2. Employee Registration and Termination Edge Cases

    function test_terminateNonRegisteredEmployee() public {
        vm.prank(hrManager);
        vm.expectRevert(EmployeeNotRegistered.selector);
        humanResources.terminateEmployee(alice);
    }

    function test_registerTerminateRegisterEmployee() public {
        _registerEmployee(alice, aliceSalary);
        assertEq(humanResources.getActiveEmployeeCount(), 1);

        _terminateEmployee(alice);
        assertEq(humanResources.getActiveEmployeeCount(), 0);

        // Re-register with a different salary
        _registerEmployee(alice, aliceSalary * 2);
        assertEq(humanResources.getActiveEmployeeCount(), 1);

        (uint256 weeklySalary, uint256 employedSince, uint256 terminatedAt) = humanResources.getEmployeeInfo(alice);
        assertEq(weeklySalary, aliceSalary * 2);
        assertEq(employedSince, block.timestamp); // Reset employedSince
        assertEq(terminatedAt, 0);
    }

    function test_terminateAlreadyTerminatedEmployee() public {
        _registerEmployee(alice, aliceSalary);
        _terminateEmployee(alice);

        // Attempt to terminate again
        vm.prank(hrManager);
        vm.expectRevert(EmployeeNotRegistered.selector);
        humanResources.terminateEmployee(alice);
    }

    // 3. Salary Withdrawal Tests

    function test_withdrawSalary_beforeRegistration() public {
        vm.prank(alice);
        vm.expectRevert(NotAuthorized.selector);
        humanResources.withdrawSalary();
    }

    function test_withdrawSalary_afterTermination() public {
        _mintTokensFor(_USDC, address(humanResources), 100_000e6);
        _registerEmployee(alice, aliceSalary);
        skip(2 days);
        _terminateEmployee(alice);
        skip(1 days);

        // Withdraw accrued salary after termination
        vm.prank(alice);
        humanResources.withdrawSalary();

        assertEq(IERC20(_USDC).balanceOf(alice),  (aliceSalary * 2) / (7*1e12));
    }

    function test_withdrawSalary_multipleTimes() public {
        _mintTokensFor(_USDC, address(humanResources), 100_000e6);
        // Expect the EmployeeRegistered event to be emitted when registering Alice
        vm.expectEmit(true, true, false, true);
        emit EmployeeRegistered(alice, aliceSalary);
        _registerEmployee(alice, aliceSalary);
        // Simulate 3 days passing (~0.428 weeks)
        skip(3 days);
    
        // Expect the SalaryWithdrawn event to be emitted with correct parameters
        vm.expectEmit(true, true, false, true);
        emit SalaryWithdrawn(alice, false, 900e6); // 900 USDC (scaled to 6 decimals)

        // Prank as Alice and perform the withdrawal
        vm.prank(alice);
        humanResources.withdrawSalary();
        
        // Assert that Alice received 900 USDC
        assertEq(IERC20(_USDC).balanceOf(alice), 900e6);
        // Simulate an additional 4 days passing (total 7 days)
        skip(4 days);
        uint256 expectedWithdraw = aliceSalary * 4/(7*1e12);
      
        // Expect the SalaryWithdrawn event to be emitted with correct parameters for the second withdrawal
        vm.expectEmit(true, true, false, true);
        emit SalaryWithdrawn(alice, false, expectedWithdraw); // 2100 USDC (scaled to 6 decimals)
        
        
        // Prank as Alice and perform the second withdrawal
        vm.prank(alice);
        humanResources.withdrawSalary();
        
        // Assert that Alice's total balance is now 3000 USDC (900 + 2100)
        assertEq(IERC20(_USDC).balanceOf(alice), 2100e6); // 3000e6 represents 3000 USDC
    }

    function test_switchCurrencyIfNotEmployee() public {
        vm.prank(charlie);
        vm.expectRevert(NotAuthorized.selector);
        humanResources.switchCurrency();
    }

    function test_terminateIfNotHrManager() public {
        _registerEmployee(alice, aliceSalary);
        vm.prank(bob);
        vm.expectRevert(NotAuthorized.selector);
        humanResources.terminateEmployee(alice);
    }


    function test_withdrawSalary_eth_withoutSwitching() public {
        _mintTokensFor(_USDC, address(humanResources), 100_000e6);
        _registerEmployee(alice, aliceSalary);
        skip(2 days);

        // Attempt to withdraw in USDC when preference is not switched
        vm.prank(alice);
        humanResources.withdrawSalary();

        assertEq(IERC20(_USDC).balanceOf(alice), ((aliceSalary * 2) / (7*1e12)));
        assertEq(alice.balance, 0);
    }

    function test_withdrawSalary_eth_withInsufficientContractBalance() public {
        _registerEmployee(alice, aliceSalary);
        vm.prank(alice);
        humanResources.switchCurrency();

        // Set HumanResources USDC balance to 0
        _mintTokensFor(_USDC, address(humanResources), 0);

        skip(2 days);

        // Attempt to withdraw ETH when contract lacks USDC
        vm.prank(alice);
        vm.expectRevert();
        humanResources.withdrawSalary();
    }

    function test_multipleEmployeesWithDifferentPreferences() public {
        _mintTokensFor(_USDC, address(humanResources), 100_000e6);

        // Register two employees with different salaries
        _registerEmployee(alice, aliceSalary);
        _registerEmployee(bob, bobSalary);

        // Set Alice to ETH mode
        vm.prank(alice);
        humanResources.switchCurrency();

        // Skip 3 days and check salaries
        skip(3 days);
        uint256 aliceExpectedSalary = (aliceSalary * 3) / 7; // Alice owed salary in USDC (18 decimals)
        uint256 bobExpectedSalary = (bobSalary * 3) / 7;

        assertApproxEqRel(
            humanResources.salaryAvailable(alice),
            aliceExpectedSalary * 1e18 / ethPrice,
            0.01e18
        );
       
        assertEq(humanResources.salaryAvailable(bob), bobExpectedSalary/1e12);

        // Alice withdraws in ETH
        vm.prank(alice);
        humanResources.withdrawSalary();

        // Bob withdraws in USDC
        vm.prank(bob);
        humanResources.withdrawSalary();

        // Verify balances
        assertApproxEqRel(alice.balance, aliceExpectedSalary * 1e18 / ethPrice, 0.01e18);
        assertEq(IERC20(_USDC).balanceOf(bob), bobExpectedSalary/1e12);
    }

    function test_largeNumberOfEmployees() public {
        _mintTokensFor(_USDC, address(humanResources), 100_000e6);
        uint256 numEmployees = 15;
        address[] memory employees = new address[](numEmployees);
        uint256 salary = 1000e18;

        // Register all employees
        for (uint256 i = 0; i < numEmployees; i++) {
            employees[i] = address(uint160(i + 1));
            _registerEmployee(employees[i], salary);
        }

        assertEq(humanResources.getActiveEmployeeCount(), numEmployees);

        // Accrue salary for all employees for 5 days
        skip(5 days);

        // Verify salaries and withdraw for a subset of employees
        for (uint256 i = 0; i < numEmployees; i += 5) {
            vm.prank(employees[i]);
            humanResources.withdrawSalary();
            uint256 expectedSalary = (salary * 5) / (7 * 1e12);
            assertApproxEqRel(IERC20(_USDC).balanceOf(employees[i]), expectedSalary, 0.01e18);
        }
    }

    function test_multipleEmployeesMixedPreferences() public {
        _mintTokensFor(_USDC, address(humanResources), 100_000e6);

        // Register employees
        _registerEmployee(alice, aliceSalary);
        _registerEmployee(bob, bobSalary);
        _registerEmployee(charlie, charlieSalary);

        // Alice and Charlie prefer ETH
        vm.prank(alice);
        humanResources.switchCurrency();
        vm.prank(charlie);
        humanResources.switchCurrency();

        // Skip 5 days
        skip(5 days);

        // Withdraw salaries
        vm.prank(alice);
        humanResources.withdrawSalary();
        vm.prank(bob);
        humanResources.withdrawSalary();
        vm.prank(charlie);
        humanResources.withdrawSalary();

        // Check balances
        uint256 aliceExpectedETH = (aliceSalary * 5 * 1e18) / (7 * ethPrice);
        uint256 bobExpectedUSDC = (bobSalary * 5) / 7;
        uint256 charlieExpectedETH = (charlieSalary * 5 * 1e18) / (7 * ethPrice);

        assertApproxEqRel(alice.balance, aliceExpectedETH, 0.01e18);
        assertEq(IERC20(_USDC).balanceOf(bob), bobExpectedUSDC / 1e12);
        assertApproxEqRel(charlie.balance, charlieExpectedETH, 0.01e18);
    }

    function test_withdrawAfterLongInactivePeriod() public {
        _mintTokensFor(_USDC, address(humanResources), 100_000e8);
        _registerEmployee(alice, aliceSalary);
        skip(365 days);
        
        vm.prank(alice);
        humanResources.withdrawSalary();

        uint256 expectedSalary = aliceSalary * 365 / 7;
        assertEq(IERC20(_USDC).balanceOf(alice), expectedSalary / 1e12);
    }



    function test_terminateNonexistentEmployee() public {
        // Attempt to terminate an unregistered employee
        vm.prank(hrManager);
        vm.expectRevert(EmployeeNotRegistered.selector);
        humanResources.terminateEmployee(alice);
    }

    function test_HRManagerUnauthorisedWithdraw() public {
        // HR Manager attempting unauthorised withdrawal
        vm.prank(hrManager);
        vm.expectRevert(NotAuthorized.selector);
        humanResources.withdrawSalary();
    }

    function test_currencySwitchAndWithdraw() public {
        // Mint funds and register Alice
        _mintTokensFor(_USDC, address(humanResources), 50_000e6);
        _registerEmployee(alice, aliceSalary);

        // Accrue salary and perform currency switches
        skip(1 days);
        vm.prank(alice);
        humanResources.switchCurrency(); // Switch to ETH

        vm.prank(alice);
        humanResources.switchCurrency(); // Switch back to USDC

        // Accumulate 7 days of salary and withdraw
        skip(6 days);
        vm.prank(alice);
        humanResources.withdrawSalary();
        assertEq(IERC20(_USDC).balanceOf(alice), aliceSalary / 1e12, "Incorrect salary after currency switch");
    }

    function test_withdrawFailsWhenNoFunds() public {
        // Register Alice and ensure contract has zero balance
        _registerEmployee(alice, aliceSalary);
        _mintTokensFor(_USDC, address(humanResources), 0);

        // Skip 7 days to accrue salary
        skip(7 days);

        // Attempt withdrawal and expect failure due to insufficient funds
        vm.prank(alice);
        vm.expectRevert();
        humanResources.withdrawSalary();
    }

    function test_salaryAfterFullWeek() public {
        // Register Alice and allow salary to accrue for a week
        _registerEmployee(alice, aliceSalary);
        skip(7 days);

        // Check that salary matches exactly one week's worth
        uint256 expectedSalary = aliceSalary / 1e12;
        assertEq(
            humanResources.salaryAvailable(alice),
            expectedSalary,
            "Mismatch in salary for a full week"
        );
    }

    function test_verifyEmployeeDetails() public {
        // Capture the current timestamp and register Alice
        uint256 registrationTime = block.timestamp;
        _registerEmployee(alice, aliceSalary);

        // Retrieve employee details and verify correctness
        (
            uint256 salary,
            uint256 startTime,
            uint256 endTime
        ) = humanResources.getEmployeeInfo(alice);

        assertEq(salary, aliceSalary, "Incorrect salary recorded");
        assertEq(startTime, registrationTime, "Start time mismatch");
        assertEq(endTime, 0, "Terminated time should be zero for active employee");
    }

    function test_doubleWithdrawalInSamePeriod() public {
        // Mint funds and register Alice
        _mintTokensFor(_USDC, address(humanResources), 10_000e6);
        _registerEmployee(alice, aliceSalary);

        // Allow partial salary accrual and perform first withdrawal
        skip(3 days);
        vm.prank(alice);
        humanResources.withdrawSalary();

        // Attempt second withdrawal without additional accrual
        vm.prank(alice);
        humanResources.withdrawSalary();

        // Verify balance remains unchanged after the second withdrawal
        uint256 expectedBalance = ((aliceSalary * 3) / 7) / 1e12;
        assertEq(
            IERC20(_USDC).balanceOf(alice),
            expectedBalance,
            "Balance increased incorrectly after second withdrawal"
        );
    }


    // --- Re-entrancy tests --- \\



    function test_reEntrancyAttack_ethWithdrawal() public {
        // Deploy malicious contract
        MaliciousReentrant malicious = new MaliciousReentrant(humanResources);

        // Register the malicious contract as an employee
        uint256 maliciousSalary = 1000e18;
        _registerEmployee(address(malicious), maliciousSalary);

        // Fund HumanResources contract
        _mintTokensFor(_USDC, address(humanResources), 100_000e6);

        // Switch to ETH to enable ETH withdrawals
        vm.prank(address(malicious));
        humanResources.switchCurrency();

        // Simulate 1 day of salary accrual
        skip(1 days);

        // Attempt the attack
        vm.expectRevert(); // The attack should fail if the contract is secure
        malicious.attack();

        // Verify no funds were stolen
        assertEq(address(malicious).balance, 0);
    }




    // --- Tests provided by Prof. --- //

    function test_registerEmployee() public {
        _registerEmployee(alice, aliceSalary);
        assertEq(humanResources.getActiveEmployeeCount(), 1);

        uint256 currentTime = block.timestamp;

        (
            uint256 weeklySalary,
            uint256 employedSince,
            uint256 terminatedAt
        ) = humanResources.getEmployeeInfo(alice);
        assertEq(weeklySalary, aliceSalary);
        assertEq(employedSince, currentTime);
        assertEq(terminatedAt, 0);

        skip(10 hours);

        _registerEmployee(bob, bobSalary);

        (weeklySalary, employedSince, terminatedAt) = humanResources
            .getEmployeeInfo(bob);
        assertEq(humanResources.getActiveEmployeeCount(), 2);

        assertEq(weeklySalary, bobSalary);
        assertEq(employedSince, currentTime + 10 hours);
        assertEq(terminatedAt, 0);
    }

    function test_registerEmployee_twice() public {
        _registerEmployee(alice, aliceSalary);
        vm.expectRevert(EmployeeAlreadyRegistered.selector);
        _registerEmployee(alice, aliceSalary);
    }

    function test_salaryAvailable_usdc() public {
        _registerEmployee(alice, aliceSalary);
        skip(2 days);
        assertEq(
            humanResources.salaryAvailable(alice),
            ((aliceSalary / 1e12) * 2) / 7
        );

        skip(5 days);
        assertEq(humanResources.salaryAvailable(alice), aliceSalary / 1e12);
    }

    function test_salaryAvailable_eth() public {
        _registerEmployee(alice, aliceSalary);
        uint256 expectedSalary = (aliceSalary * 1e18 * 2) / ethPrice / 7;
        vm.prank(alice);
        humanResources.switchCurrency();
        skip(2 days);
        assertApproxEqRel(
            humanResources.salaryAvailable(alice),
            expectedSalary,
            0.01e18
        );
        skip(5 days);
        expectedSalary = (aliceSalary * 1e18) / ethPrice;
        assertApproxEqRel(
            humanResources.salaryAvailable(alice),
            expectedSalary,
            0.01e18
        );
    }

    function test_withdrawSalary_usdc() public {
        _mintTokensFor(_USDC, address(humanResources), 10_000e6);
        _registerEmployee(alice, aliceSalary);
        skip(2 days);
        vm.prank(alice);
        humanResources.withdrawSalary();
        assertEq(
            IERC20(_USDC).balanceOf(address(alice)),
            ((aliceSalary / 1e12) * 2) / 7
        );

        skip(5 days);
        vm.prank(alice);
        humanResources.withdrawSalary();
        assertEq(IERC20(_USDC).balanceOf(address(alice)), aliceSalary / 1e12);
    }

    function test_withdrawSalary_eth() public {
        _mintTokensFor(_USDC, address(humanResources), 10_000e6);
        _registerEmployee(alice, aliceSalary);
        uint256 expectedSalary = (aliceSalary * 1e18 * 2) / ethPrice / 7;
        vm.prank(alice);
        humanResources.switchCurrency();
        skip(2 days);
        vm.prank(alice);
        humanResources.withdrawSalary();
        assertApproxEqRel(alice.balance, expectedSalary, 0.01e18);
        skip(5 days);
        expectedSalary = (aliceSalary * 1e18) / ethPrice;
        vm.prank(alice);
        humanResources.withdrawSalary();
        assertApproxEqRel(alice.balance, expectedSalary, 0.01e18);
    }

    function test_reregisterEmployee() public {
        _mintTokensFor(_USDC, address(humanResources), 10_000e6);
        _registerEmployee(alice, aliceSalary);
        skip(2 days);
        vm.prank(hrManager);
        humanResources.terminateEmployee(alice);
        skip(1 days);
        _registerEmployee(alice, aliceSalary * 2);

        skip(5 days);
        vm.prank(alice);
        humanResources.withdrawSalary();
        uint256 expectedSalary = ((aliceSalary * 2) / 7) +
            ((aliceSalary * 2 * 5) / 7);
        assertEq(
            IERC20(_USDC).balanceOf(address(alice)),
            expectedSalary / 1e12
        );
    }


    // Helper functions
    function _terminateEmployee(address employeeAddress) internal {
        vm.prank(hrManager);
        humanResources.terminateEmployee(employeeAddress);
    }

    function _registerEmployee(address employeeAddress, uint256 salary) public {
        vm.prank(hrManager);
        humanResources.registerEmployee(employeeAddress, salary);
    }

    function _mintTokensFor(
        address token_,
        address account_,
        uint256 amount_
    ) internal {
        stdstore
            .target(token_)
            .sig(IERC20(token_).balanceOf.selector)
            .with_key(account_)
            .checked_write(amount_);
    }
}

// Re-entrancy Malicious Contracts //
contract MaliciousReentrant {
    HumanResources public target;
    bool public attackInProgress;
    uint256 public attackCount;

    constructor(HumanResources _target) {
        target = _target;
    }

    receive() external payable {
    if (attackInProgress && attackCount < 2) { // Prevent infinite recursion
        attackCount++;
        console.log("MaliciousReentrant executing reentrant withdrawSalary. Count: %s", attackCount);
        target.withdrawSalary();
    }
    else{
        console.log("Initial withdraw call already finished");
    }
}


    function attack() external {
        attackInProgress = true;
        console.log("Initiating first withdraw reentrancy call");
        target.withdrawSalary();
        console.log("First attack withdraw call complete");
        attackInProgress = false;
    }
}
