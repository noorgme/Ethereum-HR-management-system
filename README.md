# HumanResources Smart Contract - Detailed Documentation

## Overview
The `HumanResources.sol` contract implements a decentralised employee management system that facilitates salary payments in USDC or ETH. Employees accrue salaries based on time elapsed, and the contract leverages **Uniswap V3** for token swaps and **Chainlink Oracles** for real-time price feeds. This document explains the implementation details of the contract, including relevant code snippets and integration specifics.

---

## Functions and Implementation Details

### 1. `registerEmployee(address employee, uint256 weeklyUsdSalary)`
**Purpose:** Adds a new employee or reactivates a previously terminated employee.  
**Implementation:** 
- If the employee is new:
  - Initialise their `weeklyUsdSalary`, `employedSince`, and other relevant fields.
- If the employee was terminated:
  - Reset `terminatedAt` and `employedSince`.
  - Update `weeklyUsdSalary`.
- Increment `activeEmployeeCount` and emit the `EmployeeRegistered` event.  
**Code:**
```solidity
function registerEmployee(address employee, uint256 weeklyUsdSalary) external managerAuth {
    Employee storage emp = employeeRegister[employee];

    if (emp.employedSince == 0) {
        emp.weeklyUsdSalary = weeklyUsdSalary;
        emp.employedSince = block.timestamp;
        emp.terminatedAt = 0;
        emp.withdrawnSalary = 0;
        emp.accruedSalary = 0;
    } else if (emp.terminatedAt != 0) {
        emp.employedSince = block.timestamp;
        emp.terminatedAt = 0;
        emp.weeklyUsdSalary = weeklyUsdSalary;
    } else {
        revert EmployeeAlreadyRegistered();
    }

    emp.isEth = false;
    activeEmployeeCount += 1;
    emit EmployeeRegistered(employee, weeklyUsdSalary);
}
```



### 2. terminateEmployee(address employee)
Purpose: Terminates an employee and halts salary accrual.
Implementation:

Compute and store any outstanding salary as accruedSalary.
Update the terminatedAt timestamp and reset withdrawnSalary.
Decrease activeEmployeeCount and emit the EmployeeTerminated event.

Code:
```solidity
function terminateEmployee(address employee) external managerAuth {
    Employee storage emp = employeeRegister[employee];

    if (emp.employedSince == 0 || emp.terminatedAt != 0) {
        revert EmployeeNotRegistered();
    }

    emp.accruedSalary += (block.timestamp - emp.employedSince) * emp.weeklyUsdSalary / 7 days - emp.withdrawnSalary;
    emp.withdrawnSalary = 0;
    emp.terminatedAt = block.timestamp;

    activeEmployeeCount -= 1;
    emit EmployeeTerminated(employee);
}
```



### 3. withdrawSalary()
*Purpose:* Allows employees to withdraw their accrued salary.
*Implementation:*

- Calculate salaryOwed based on elapsed time since the last withdrawal.

- If ETH is preferred:
    - Convert USDC to ETH using convertUSDCtoEth() and Uniswap.
    - Ensure the swap result respects slippage limits.
    - Transfer ETH to the employee.
- If USDC is preferred, transfer directly.
    - Reset accruedSalary and emit SalaryWithdrawn event.

Code:
```solidity
function withdrawSalary() public nonReentrant {
    Employee storage emp = employeeRegister[msg.sender];

    uint256 salaryOwed = emp.accruedSalary;
    if (emp.terminatedAt == 0) {
        salaryOwed += ((block.timestamp - emp.employedSince) * emp.weeklyUsdSalary) / 7 days - emp.withdrawnSalary;
        emp.withdrawnSalary += salaryOwed;
    }

    if (emp.isEth) {
        uint256 ethAmount = convertUSDCtoEth(salaryOwed);
        IERC20(usdc).approve(uniswapRouter, salaryOwed / 1e12);
        ISwapRouter.ExactInputSingleParams memory params = ISwapRouter.ExactInputSingleParams({
            tokenIn: usdc,
            tokenOut: weth,
            fee: 500,
            recipient: address(this),
            deadline: block.timestamp + 15,
            amountIn: salaryOwed / 1e12,
            amountOutMinimum: (ethAmount * 98) / 100,
            sqrtPriceLimitX96: 0
        });

        uint256 wethReceived = ISwapRouter(uniswapRouter).exactInputSingle(params);
        IWETH(weth).withdraw(wethReceived);
        payable(msg.sender).transfer(wethReceived);
    } else {
        IERC20(usdc).transfer(msg.sender, salaryOwed / 1e12);
    }

    emp.accruedSalary = 0;
    emit SalaryWithdrawn(msg.sender, emp.isEth, salaryOwed);
}

```

### 4. switchCurrency()
*Purpose:* Toggles the employee's preferred currency for salary payments.
*Implementation:*

- Withdraw any pending salary.
- Flip the isEth boolean flag.
- Emit the CurrencySwitched event.

Code:
```solidity
function switchCurrency() external employeeAuth {
    withdrawSalary();
    Employee storage emp = employeeRegister[msg.sender];
    emp.isEth = !emp.isEth;
    emit CurrencySwitched(msg.sender, emp.isEth);
}

```
### Integration with AMM and Oracle
#### AMM Integration (Uniswap V3)

The contract uses Uniswap V3 to swap USDC to ETH:

- Approval: The contract approves Uniswap to spend the required USDC.
- Swap Execution: Calls exactInputSingle with the specified parameters.
- Sets slippage tolerance to ±2%.
- Receives WETH after the swap.
- ETH Conversion: WETH is converted to ETH using IWETH.withdraw().

Code:
```solidity
IERC20(usdc).approve(uniswapRouter, salaryOwed / 1e12);
ISwapRouter.ExactInputSingleParams memory params = ISwapRouter.ExactInputSingleParams({
    tokenIn: usdc,
    tokenOut: weth,
    fee: 500,
    recipient: address(this),
    deadline: block.timestamp + 15,
    amountIn: salaryOwed / 1e12,
    amountOutMinimum: (expectedEth * 98) / 100,
    sqrtPriceLimitX96: 0
});

uint256 wethReceived = ISwapRouter(uniswapRouter).exactInputSingle(params);
IWETH(weth).withdraw(wethReceived);
payable(msg.sender).transfer(wethReceived);

```

### Oracle Integration (Chainlink)
The contract integrates a Chainlink price feed for accurate ETH/USD price data:

- Price Fetching: Fetches the latest ETH price in USD using latestRoundData.
- Conversion: Converts a USDC amount to ETH based on the oracle price.

Code:
```solidity
function getEthPrice() private view returns (uint256) {
    AggregatorV3Interface oracle = AggregatorV3Interface(usdcEthOracle);
    (, int256 price, , , ) = oracle.latestRoundData();
    require(price > 0, "Invalid price");
    return uint256(price);
}

function convertUSDCtoEth(uint256 usdcAmount) private view returns (uint256) {
    uint256 ethPrice = getEthPrice(); // ETH price in USD with 8 decimals
    return (usdcAmount * 1e8) / ethPrice; // Return ETH amount in 18 decimals
}

```
