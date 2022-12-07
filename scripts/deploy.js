async function main() {
  const [deployer] = await ethers.getSigners();

  console.log("Deploying contracts with the account:", deployer.address);

  console.log("Account balance:", (await deployer.getBalance()).toString());

  // const Map = await ethers.getContractFactory("IterableMapping");
  // const map = await Map.deploy();
  // // await map.wait();
  // console.log("Mapping address:", map.address);

  const Token = await ethers.getContractFactory("BloXie", {
    libraries: {
      IterableMapping: "0xfce64a0e8127eb939b91f59a2efda5caab6ad0ca",
    },
  });

  const token = await Token.deploy();
  // await token.wait();
  console.log("Token address:", token.address);
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });
