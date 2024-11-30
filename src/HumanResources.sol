// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.17;

import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IHumanResources} from "./interfaces/IHumanResources.sol";
import {AggregatorV3Interface} from "./interfaces/AggregatorV3Interface.sol";
import {ISwapRouter} from "./interfaces/ISwapRouter.sol";

contract HumanResources is IHumanResources, ReentrancyGuard {
    struct Employee {
        uint256 weeklyUsdSalary; // Based in USDC
        uint256 employedSince;
        uint256 terminatedAt;
        uint256 withdrawnSalary;
        uint256 accruedSalary;
        bool isEth; // false = USDC (default) | true = ETH
    }

    // Token addresses
    address public usdc;
    address public weth;
    

    // USDC/ETH Price Oracle address
    address public usdcEthOracle;

    // Uniswap Router for USDC<>ETH Swaps
    address public uniswapRouter;

    address immutable public _hrManager;
    mapping(address=>Employee) employeeRegister;
    uint256 activeEmployeeCount = 0;
    
    constructor (address _usdc, address _weth, address _usdcEthOracle, address _uniswapRouter) {
        _hrManager = msg.sender;
        usdc = _usdc;
        weth = _weth;
        usdcEthOracle = _usdcEthOracle;
        uniswapRouter = _uniswapRouter;
    }

    modifier managerAuth(){
        if (msg.sender != _hrManager){
            revert NotAuthorized();
        }
        _;
    }

    modifier employeeAuth(){
        if (employeeRegister[msg.sender].employedSince == 0 || employeeRegister[msg.sender].terminatedAt != 0){
            revert EmployeeNotRegistered();
        }
        _;
    }

    /// Registers an employee in the HR system
    function registerEmployee(address employee, uint256 weeklyUsdSalary) external managerAuth {
        Employee storage emp = employeeRegister[employee];

        if (emp.employedSince == 0) {
            // New registration
            emp.weeklyUsdSalary = weeklyUsdSalary;
            emp.employedSince = block.timestamp;
            emp.terminatedAt = 0;
            emp.withdrawnSalary = 0;
            emp.accruedSalary = 0;
        } else if (emp.terminatedAt != 0) {
            // Reinstate terminated employee
            emp.employedSince = block.timestamp;
            emp.terminatedAt = 0;
            
        } else {
            // Already active
            revert EmployeeAlreadyRegistered();
        }

        // Reset Currency Preference to USDT
        emp.isEth = false;

        activeEmployeeCount += 1;
        emit EmployeeRegistered(employee, weeklyUsdSalary);
    }

    // Terminate an employee. Only callable by an HR Manager
    function terminateEmployee(address employee) external managerAuth {
        Employee storage emp = employeeRegister[employee];

        // Cannot fire if not employed/currently terminated
        if (emp.employedSince == 0 || emp.terminatedAt != 0) {
            revert EmployeeNotRegistered();
        }

        // Update accrued salary with currently owed salary from this period
        emp.accruedSalary += (block.timestamp - emp.employedSince) * emp.weeklyUsdSalary / 7 days - emp.withdrawnSalary;

        // Reset withdrawn salary
        emp.withdrawnSalary = 0;

        // Terminate employee
        emp.terminatedAt = block.timestamp;

        activeEmployeeCount -= 1;
        emit EmployeeTerminated(employee);
    }

    // Toggle currency between USDT (0) and ETH (1)
    function switchCurrency() external employeeAuth(){
        Employee storage emp = employeeRegister[msg.sender];

        // Withdraw pending salary
        withdrawSalary();
        
        // Switch currency preference
        emp.isEth = !emp.isEth;
        emit CurrencySwitched(msg.sender, emp.isEth);
        
    }

    function withdrawSalary() public nonReentrant {
        Employee storage emp = employeeRegister[msg.sender];
        uint256 salaryOwed;
        // If never employed
        if (emp.employedSince == 0){
            revert NotAuthorized(); // ensure this is the correct error to throw. Maybe "EmployeeNotRegistered()"?
        }

        // Calculate salary owed
        
        if (emp.terminatedAt == 0){
            // If employed
            salaryOwed = ((block.timestamp - emp.employedSince) * emp.weeklyUsdSalary)/ 7 days - emp.withdrawnSalary;
            emp.withdrawnSalary += salaryOwed;

            // Add unclaimed accrued salary from previous employment period(s)
            salaryOwed += emp.accruedSalary;
        }
        else {
            // If terminated, withdraw accruedSalary and reset to 0
            salaryOwed = emp.accruedSalary;
            
        }
        

        require (salaryOwed > 0, "No salary available to withdraw");

        if (emp.isEth){
            // Convert USDC salary owed amount to ETH
            expectedEth = convertUSDCtoEth(salaryOwed);

            /* Approve the Uniswap router to spend the salary amount in USDC on behalf of 
            this contract (to perform the USDC->ETH Swap) */
            IERC20(usdc).approve(address(uniswapRouter), salaryOwed);
            ISwapRouter.ExactInputSingleParams memory params = ISwapRouter
                .ExactInputSingleParams({
                tokenIn: usdc,
                tokenOut: weth,
                fee: 3000, // Fee tier (0.3%)
                recipient: address(this), // Send the WETH to this contract
                deadline: block.timestamp + 15,
                amountIn: salaryOwed, //USDC amount 
                amountOutMinimum: (expectedEth * 98) / 100, // Allow up to 2% slippage
                sqrtPriceLimitX96: 0
            });

            // Execute the USDC->WETH Swap using a single LP
            uint256 wethReceived = ISwapRouter(uniswapRouter).exactInputSingle(params);

            // Convert WETH to ETH and send to employee
            IWETH(weth).withdraw(wethReceived);
            payable(msg.sender).transfer(wethReceived);

            salaryOwed = expectedEth;
        }
        else {
            // Transfer USDC to employee
            IERC20(usdc).transfer(msg.sender, salaryOwed);
        }

        // Reset accrued salary now that it has been claimed
        emp.accruedSalary = 0;
        emit SalaryWithdrawn(msg.sender, emp.isEth, salaryOwed);

    }

    function salaryAvailable(address employee) external view returns (uint256){
        Employee memory emp = employeeRegister[employee];
        uint256 salaryOwed;
        // If never registered, return 0
        if (emp.employedSince == 0){
            return 0;
        }

        // Current employee
        else if (emp.terminatedAt == 0){
            salaryOwed = ((block.timestamp - emp.employedSince) * emp.weeklyUsdSalary)/ 7 days - emp.withdrawnSalary;
        }

        // Terminated
        else {
            salaryOwed = emp.accruedSalary;
        }
        
        // Handle currency preference and return salary available
        if (emp.isEth){
            return convertUSDCtoEth(salaryOwed);
        }
        else {
            return salaryOwed;
        }
    }

    // Return address of the HR manager so you can report him to the HR manager manager (HR Final Boss)
    function hrManager() external view returns (address){
        return _hrManager;
    }

    function getActiveEmployeeCount() external view returns (uint256){
        return activeEmployeeCount;
    }

    function getEmployeeInfo(address employee) external view returns (uint256 weeklyUsdSalary, uint256 employedSince, uint256 terminatedAt){
        Employee storage emp = employeeRegister[employee];

        return (emp.weeklyUsdSalary, emp.employedSince, emp.terminatedAt);
    }


    // --- Private functions ----

    // Returns ETH/USDC Price with 6 decimals (Chainlink Oracle)
    function getEthPrice() private view returns (uint256) {
        AggregatorV3Interface oracle = AggregatorV3Interface(usdcEthOracle);
        (, int256 price, , , ) = oracle.latestRoundData();
        require (price > 0, "Invalid price");
        return uint256(price);
    }

    // Find current ETH value of a given USDC amount (Chainlink Oracle)
    function convertUSDCtoEth(uint256 usdcAmount) private view returns (uint256){
        uint256 ethPrice = getEthPrice(); // ETH price in USD with 8 decimals
        // Convert usdcAmount from 6 decimals to 18 decimals by multiplying by 1e12
        uint256 usdcAmountIn18 = usdcAmount * 1e12;
        // ETH amount in wei = (usdcAmountIn18 * 1e18) / ethPrice
        // Adjust for ETH price decimals
        return (usdcAmountIn18 * 1e18) / ethPrice;
    }





}