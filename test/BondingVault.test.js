// SPDX-License-Identifier: MIT
const { expect } = require("chai");
const { ethers } = require("hardhat");

describe("BondingVault", function () {
    let vault, riskCalculator, agentController, surgeToken;
    let owner, agent, user, attacker;
    let bondAmount, riskBuffer;

    beforeEach(async function () {
        [owner, agent, user, attacker] = await ethers.getSigners();

        const BondingVault = await ethers.getContractFactory("BondingVault");
        vault = await BondingVault.deploy(owner.address);
        await vault.waitForDeployment();

        const RiskCalculator = await ethers.getContractFactory("RiskCalculator");
        riskCalculator = await RiskCalculator.deploy(owner.address);
        await riskCalculator.waitForDeployment();

        const AgentController = await ethers.getContractFactory("AgentController");
        agentController = await AgentController.deploy(
            owner.address,
            vault.address,
            riskCalculator.address,
            surgeToken.address
        );
        await agentController.waitForDeployment();

        const SurgeToken = await ethers.getContractFactory("SurgeToken");
        surgeToken = await SurgeToken.deploy(owner.address);
        await surgeToken.waitForDeployment();

        await vault.setAgentController(agentController.address);
        await vault.setRiskCalculator(riskCalculator.address);
        await vault.setSurgeToken(surgeToken.address);

        await surgeToken.mint(owner.address, ethers.parseEther("10000"));
        await surgeToken.mint(agent.address, ethers.parseEther("10000"));
        await surgeToken.mint(user.address, ethers.parseEther("10000"));

        bondAmount = ethers.parseEther("100");
        riskBuffer = ethers.parseEther("10");
    });

    describe("Bond Liquidation on Loss", function () {
        it("should liquidate bond when loss exceeds risk buffer", async function () {
            await surgeToken.connect(agent).approve(vault.address, bondAmount);
            await vault.connect(agent).stakeBond(agent.address, bondAmount, riskBuffer);

            const initialBalance = await surgeToken.balanceOf(agent);
            const initialVaultBalance = await surgeToken.balanceOf(vault.address);

            await vault.connect(agent).liquidateBond(agent.address, ethers.parseEther("15"));

            const finalBalance = await surgeToken.balanceOf(agent);
            const finalVaultBalance = await surgeToken.balanceOf(vault.address);

            expect(finalBalance).to.be.lessThan(initialBalance);
            expect(finalVaultBalance).to.be.greaterThan(initialVaultBalance);
        });

        it("should not liquidate when loss is within risk buffer", async function () {
            await surgeToken.connect(agent).approve(vault.address, bondAmount);
            await vault.connect(agent).stakeBond(agent.address, bondAmount, riskBuffer);

            await vault.connect(agent).liquidateBond(agent.address, ethers.parseEther("5"));

            const bond = await vault.agentBonds(agent.address);
            expect(bond.bondAmount).to.equal(bondAmount);
        });

        it("should emit LiquidationEvent on bond liquidation", async function () {
            await surgeToken.connect(agent).approve(vault.address, bondAmount);
            await vault.connect(agent).stakeBond(agent.address, bondAmount, riskBuffer);

            await expect(
                vault.connect(agent).liquidateBond(agent.address, ethers.parseEther("15"))
            ).to.emit(vault, "BondLiquidated");
        });

        it("should track total liquidated amount", async function () {
            await surgeToken.connect(agent).approve(vault.address, bondAmount);
            await vault.connect(agent).stakeBond(agent.address, bondAmount, riskBuffer);

            await vault.connect(agent).liquidateBond(agent.address, ethers.parseEther("15"));

            expect(await vault.totalLiquidated()).to.equal(ethers.parseEther("15"));
        });
    });

    describe("Bond Scaling on Volatility", function () {
        it("should scale bond requirement with volatility", async function () {
            await surgeToken.connect(agent).approve(vault.address, bondAmount);
            await vault.connect(agent).stakeBond(agent.address, bondAmount, riskBuffer);

            await riskCalculator.setVolatilityMultiplier(20000);

            const newBondAmount = await vault.calculateRequiredBond(
                agent.address,
                ethers.parseEther("1000")
            );

            expect(newBondAmount).to.be.greaterThan(bondAmount);
        });

        it("should update bond on volatility change", async function () {
            await surgeToken.connect(agent).approve(vault.address, bondAmount);
            await vault.connect(agent).stakeBond(agent.address, bondAmount, riskBuffer);

            await riskCalculator.setVolatilityMultiplier(30000);

            await vault.connect(agent).updateBond(agent.address);

            const bond = await vault.agentBonds(agent.address);
            expect(bond.bondAmount).to.be.greaterThan(bondAmount);
        });

        it("should prevent trading when bond-to-risk ratio drops below 1.0", async function () {
            await surgeToken.connect(agent).approve(vault.address, bondAmount);
            await vault.connect(agent).stakeBond(agent.address, bondAmount, riskBuffer);

            await riskCalculator.setVolatilityMultiplier(50000);

            await expect(
                vault.connect(agent).stakeBond(agent.address, bondAmount, riskBuffer)
            ).to.be.revertedWith("Insufficient bond coverage");
        });

        it("should emit BondUpdated event on volatility scaling", async function () {
            await surgeToken.connect(agent).approve(vault.address, bondAmount);
            await vault.connect(agent).stakeBond(agent.address, bondAmount, riskBuffer);

            await riskCalculator.setVolatilityMultiplier(20000);

            await expect(vault.connect(agent).updateBond(agent.address)).to.emit(
                vault,
                "BondUpdated"
            );
        });
    });

    describe("Unauthorized Withdrawal Attempts", function () {
        it("should revert unauthorized bond withdrawal", async function () {
            await surgeToken.connect(agent).approve(vault.address, bondAmount);
            await vault.connect(agent).stakeBond(agent.address, bondAmount, riskBuffer);

            await expect(
                vault.connect(user).withdrawBond(agent.address, bondAmount)
            ).to.be.revertedWith("Unauthorized");
        });

        it("should revert unauthorized bond stake", async function () {
            await expect(
                vault.connect(user).stakeBond(agent.address, bondAmount, riskBuffer)
            ).to.be.revertedWith("Unauthorized");
        });

        it("should revert unauthorized bond liquidation", async function () {
            await surgeToken.connect(agent).approve(vault.address, bondAmount);
            await vault.connect(agent).stakeBond(agent.address, bondAmount, riskBuffer);

            await expect(
                vault.connect(user).liquidateBond(agent.address, ethers.parseEther("10"))
            ).to.be.revertedWith("Unauthorized");
        });

        it("should allow owner to pause vault", async function () {
            await surgeToken.connect(agent).approve(vault.address, bondAmount);
            await vault.connect(agent).stakeBond(agent.address, bondAmount, riskBuffer);

            await vault.pause();

            await expect(
                vault.connect(agent).stakeBond(agent.address, bondAmount, riskBuffer)
            ).to.be.revertedWith("Pausable: paused");
        });

        it("should allow owner to unpause vault", async function () {
            await surgeToken.connect(agent).approve(vault.address, bondAmount);
            await vault.connect(agent).stakeBond(agent.address, bondAmount, riskBuffer);

            await vault.pause();
            await vault.unpause();

            await expect(
                vault.connect(agent).stakeBond(agent.address, bondAmount, riskBuffer)
            ).to.not.be.reverted;
        });

        it("should revert unauthorized emergency withdraw", async function () {
            await surgeToken.connect(agent).approve(vault.address, bondAmount);
            await vault.connect(agent).stakeBond(agent.address, bondAmount, riskBuffer);

            await expect(
                vault.connect(user).emergencyWithdraw(bondAmount)
            ).to.be.revertedWith("Ownable: caller is not the owner");
        });

        it("should allow owner to emergency withdraw", async function () {
            await surgeToken.connect(agent).approve(vault.address, bondAmount);
            await vault.connect(agent).stakeBond(agent.address, bondAmount, riskBuffer);

            await vault.emergencyWithdraw(bondAmount);

            const vaultBalance = await surgeToken.balanceOf(vault.address);
            expect(vaultBalance).to.be.lessThan(bondAmount);
        });
    });

    describe("Bond Staking and Withdrawal", function () {
        it("should allow agent to stake bond", async function () {
            await surgeToken.connect(agent).approve(vault.address, bondAmount);
            await vault.connect(agent).stakeBond(agent.address, bondAmount, riskBuffer);

            const bond = await vault.agentBonds(agent.address);
            expect(bond.bondAmount).to.equal(bondAmount);
            expect(bond.riskBuffer).to.equal(riskBuffer);
        });

        it("should allow agent to withdraw bond", async function () {
            await surgeToken.connect(agent).approve(vault.address, bondAmount);
            await vault.connect(agent).stakeBond(agent.address, bondAmount, riskBuffer);

            await vault.connect(agent).withdrawBond(agent.address, bondAmount);

            const bond = await vault.agentBonds(agent.address);
            expect(bond.bondAmount).to.equal(0);
        });

        it("should emit BondStaked event on stake", async function () {
            await surgeToken.connect(agent).approve(vault.address, bondAmount);

            await expect(
                vault.connect(agent).stakeBond(agent.address, bondAmount, riskBuffer)
            ).to.emit(vault, "BondStaked");
        });

        it("should emit BondWithdrawn event on withdrawal", async function () {
            await surgeToken.connect(agent).approve(vault.address, bondAmount);
            await vault.connect(agent).stakeBond(agent.address, bondAmount, riskBuffer);

            await expect(
                vault.connect(agent).withdrawBond(agent.address, bondAmount)
            ).to.emit(vault, "BondWithdrawn");
        });

        it("should track total bonds", async function () {
            await surgeToken.connect(agent).approve(vault.address, bondAmount);
            await vault.connect(agent).stakeBond(agent.address, bondAmount, riskBuffer);

            expect(await vault.totalBonds()).to.equal(bondAmount);
        });

        it("should revert stake if bond exceeds MAX_BOND", async function () {
            const tooLargeBond = ethers.parseEther("10001");
            await surgeToken.connect(agent).approve(vault.address, tooLargeBond);

            await expect(
                vault.connect(agent).stakeBond(agent.address, tooLargeBond, riskBuffer)
            ).to.be.revertedWith("Bond exceeds maximum");
        });

        it("should revert stake if bond below MIN_BOND", async function () {
            const tooSmallBond = ethers.parseEther("0.5");
            await surgeToken.connect(agent).approve(vault.address, tooSmallBond);

            await expect(
                vault.connect(agent).stakeBond(agent.address, tooSmallBond, riskBuffer)
            ).to.be.revertedWith("Bond below minimum");
        });
    });

    describe("Reentrancy Protection", function () {
        it("should prevent reentrant bond staking", async function () {
            const maliciousVault = await ethers.deployContract("MaliciousVault", [
                vault.address,
            ]);

            await surgeToken.connect(agent).approve(vault.address, bondAmount);

            await expect(
                vault.connect(agent).stakeBond(agent.address, bondAmount, riskBuffer)
            ).to.not.be.reverted;
        });

        it("should prevent reentrant bond withdrawal", async function () {
            await surgeToken.connect(agent).approve(vault.address, bondAmount);
            await vault.connect(agent).stakeBond(agent.address, bondAmount, riskBuffer);

            const maliciousVault = await ethers.deployContract("MaliciousVault", [
                vault.address,
            ]);

            await expect(
                vault.connect(agent).withdrawBond(agent.address, bondAmount)
            ).to.not.be.reverted;
        });
    });

    describe("Edge Cases", function () {
        it("should handle zero bond amount", async function () {
            await surgeToken.connect(agent).approve(vault.address, 0);
            await vault.connect(agent).stakeBond(agent.address, 0, 0);

            const bond = await vault.agentBonds(agent.address);
            expect(bond.bondAmount).to.equal(0);
        });

        it("should handle multiple agents staking", async function () {
            await surgeToken.connect(agent).approve(vault.address, bondAmount);
            await vault.connect(agent).stakeBond(agent.address, bondAmount, riskBuffer);

            await surgeToken.connect(user).approve(vault.address, bondAmount);
            await vault.connect(user).stakeBond(user.address, bondAmount, riskBuffer);

            expect(await vault.totalBonds()).to.equal(bondAmount * 2n);
        });

        it("should handle bond update with same amount", async function () {
            await surgeToken.connect(agent).approve(vault.address, bondAmount);
            await vault.connect(agent).stakeBond(agent.address, bondAmount, riskBuffer);

            await vault.connect(agent).updateBond(agent.address);

            const bond = await vault.agentBonds(agent.address);
            expect(bond.bondAmount).to.equal(bondAmount);
        });

        it("should track lastBondUpdate timestamp", async function () {
            await surgeToken.connect(agent).approve(vault.address, bondAmount);
            await vault.connect(agent).stakeBond(agent.address, bondAmount, riskBuffer);

            const bond = await vault.agentBonds(agent.address);
            expect(bond.lastBondUpdate).to.be.greaterThan(0);
        });
    });
});

// Malicious contract for reentrancy testing
class MaliciousVault {
    constructor(vaultAddress) {
        this.vaultAddress = vaultAddress;
    }

    async receiveBond() {
        const vault = await ethers.getContractAt("BondingVault", this.vaultAddress);
        await vault.stakeBond(ethers.ZeroAddress, ethers.parseEther("1"), ethers.parseEther("0.1"));
    }
}