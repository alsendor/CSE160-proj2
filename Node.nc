/*
* ANDES Lab - University of California, Merced
* This class provides the basic functions of a network node.
*
* @author UCM ANDES Lab
* @date   2013/09/03
*
*/
#include <Timer.h>
#include "includes/command.h"
#include "includes/packet.h"
#include "includes/CommandMsg.h"
#include "includes/sendInfo.h"
#include "includes/channels.h"

/*typedef nx_struct Neighbor {
   nx_uint16_t Node;
   nx_uint16_t pingNumber;
}Neighbor;
*/
module Node{

    uses interface Boot;
    uses interface SplitControl as AMControl;
    uses interface Receive;
    uses interface SimpleSend as Sender;
    uses interface CommandHandler;

    uses interface List<pack> as PackList;     //Create list of pack called PackList
/*
    uses interface List<Neighbor> as NeighborsList; //Create list of neighbors
    uses interface List<Neighbor> as NeighborsDropped; //Creates list of dropped neighbors
    uses interface List<Neighbor> as NeighborCosts; //Creates list of neighboring nodes costs
    uses interface List<LinkState> as RoutingTable; //Link State table used for Routing route
    uses interface List<LinkState> as ConfirmedTable; //ConfirmedTable table
    uses interface List<LinkState> as TentativeTable; //TentativeTable Table
    uses interface Hashmap<int> as nextTable;
*/

    uses interface Random as Random;

    uses interface Timer<TMilli> as Timer;
    uses interface Timer<TMilli> as tableTimer; //Creates implementation of timer for neighbor periods

}

implementation{

    uint16_t sequenceCounter = 0;             //Create a sequence counter
  //uint16_t accessCounter = 0;               //Create an access counter
    uint8_t maxHops = 18;
    uint8_t NeighborsListSize = 19;
    uint8_t maxNeighborTTL = 20;
    uint8_t Neighbors[19];
    uint8_t Routing[255][3];

    pack sendPackage;
    bool isFired = FALSE;
    bool initialized = FALSE;

    void discoverNeighbors();
    void makePack(pack *Package, uint16_t src, uint16_t dest, uint16_t TTL, uint16_t Protocol, uint16_t seq, uint8_t *payload, uint8_t length);

    void packLog(pack *Package);           //Function to create a log of packs
    bool packSeen(pack *Package);            //Function to check for previously seen packs

    //void route(uint16_t Dest, uint16_t Cost, uint16_t Next);

    //Functions for handling neighbor nodes
    void route();
    void addNeighbor(uint8_t Neighbor);
    void lessNeighborTTL();
    void sendToNeighbor(pack *recievedMsg);
    void destNeighbor(pack *recievedMsg);
    void scanForNeighbors();

    //Distance Vector table initialize, insert new, merge route, split horizon, and send table to all neighbors
    void initializeRT();
    void insertRT(uint8_t dest, uint8_t cost, uint8_t nextHop);
    bool mergeRoute(uint8_t *newRoute, uint8_t src);
    void splitHorizon(uint8_t nextHop);
    void sendRT();

    //Period timer function
    event void Timer.fired() {
       uint32_t Tinitial, Tinterval;     //Create inital time = 0 and the time over any interval
       scanForNeighbors();
       //dbg(NEIGHBOR_CHANNEL,"Neighboring nodes %s\n", Neighbor);
       //dbg(NEIGHBOR_CHANNEL,"Neighboring nodes %s\n", Neighbor);

       Tinitial = 20000 + (call Random.rand32() % 1000);
       Tinterval = 25000 + (call Random.rand32() % 10000);

       if (!isFired) {
         call tableTimer.startPeriodic(Tinitial, Tinterval);
         isFired = TRUE;
       }
     }

    //Table timer function
     event void tableTimer.fired() {
       if (initialized == FALSE) {
         initializeRT();
         initialized = TRUE;
       }
       else {
         sendRT();
       }
     }

    event void Boot.booted() {
    uint8_t Tinitial, Tinterval;
    call AMControl.start();

    Tinitial = 500 + (call Random.rand32() % 1000);
    Tinterval = 2500 + (call Random.rand32() % 10000);
    call Timer.startPeriodicAt(Tinitial, Tinterval);

    dbg(GENERAL_CHANNEL, "Booted\n");
  }

    event void AMControl.startDone(error_t err){
      if(err == SUCCESS){
          dbg(GENERAL_CHANNEL, "Radio On\n");
      }
      else {
          call AMControl.start(); //Retry until success
          }
      }

      event void AMControl.stopDone(error_t err){}

    event message_t* Receive.receive(message_t* msg, void* payload, uint8_t len){
      bool diffRoute = FALSE;
      pack *recievedMsg;
      recievedMsg = (pack *)payload;

      if (recievedMsg->protocol == PROTOCOL_DV) {     //Recieve DV message
        dbg(GENERAL_CHANNEL, "Recieved DV Packet\n");
      }

      //Timer ran out of time to live and has died
      if (len == sizeof(pack)) {
        if (recievedMsg->TTL == 0){
          dbg(GENERAL_CHANNEL, "\tPackage(%d,%d) TTL ran out\n", recievedMsg->src, recievedMsg->dest);
          return msg;
        }

      //If packet has been seen
      else if (packSeen(recievedMsg)) {
        return msg;
      }

      //Ping and ping reply
      if (recievedMsg->protocol == PROTOCOL_PING && recievedMsg->dest == TOS_NODE_ID) {
        dbg(FLOODING_CHANNEL, "\tPackage(%d,%d) ------------------------------------------------------>>>>Ping: %s\n", recievedMsg->src, recievedMsg->dest, recievedMsg->payload);
        packLog(&sendPackage);

        //sending reply
        sequenceCounter++;
        makePack(&sendPackage, recievedMsg->dest, recievedMsg->src, MAX_TTL, PROTOCOL_PINGREPLY, sequenceCounter, (uint8_t*)recievedMsg->payload, len);
        packLog(&sendPackage);
        call Sender.send(sendPackage, AM_BROADCAST_ADDR);
        return msg;
      }
      //Ping Reply
      else if (recievedMsg->protocol == PROTOCOL_PINGREPLY && recievedMsg->dest == TOS_NODE_ID) {
        dbg(FLOODING_CHANNEL, "\tPackage(%d,%d) ------------------------------------------------------>>>>Ping Reply: %s\n", recievedMsg->src, recievedMsg->dest, recievedMsg->payload);
        packLog(&sendPackage);
        return msg;
      }
      //Neighbor discovery timer
      else if (recievedMsg->protocol == PROTOCOL_PING && recievedMsg->dest == AM_BROADCAST_ADDR) {
        dbg(GENERAL_CHANNEL, "Neighbor Discovery Packet Source: %d\n", recievedMsg->src);
        addNeighbor(recievedMsg->src);
        packLog(recievedMsg);
        return msg;
      }
      //Receive DV table
      else if (recievedMsg->dest == TOS_NODE_ID && recievedMsg->protocol == PROTOCOL_DV) {
        dbg(GENERAL_CHANNEL, "Calling Merge Route\n");
        diffRoute = mergeRoute((uint8_t*) recievedMsg->payload, (uint8_t) recievedMsg->src);
        if(diffRoute){
          sendRT();
        }
        return msg;
      }
      //If packet is not at intended destination
      else if (recievedMsg->dest != TOS_NODE_ID && recievedMsg->dest != AM_BROADCAST_ADDR) {
        recievedMsg->TTL--;
        makePack(&sendPackage, recievedMsg->src, recievedMsg->dest, recievedMsg->TTL, recievedMsg->protocol, recievedMsg->seq, (uint8_t*)recievedMsg->payload, len);
        packLog(&sendPackage);
        sendToNeighbor(&sendPackage);
        return msg;
      }
      dbg(GENERAL_CHANNEL, "\tUnknown Packet Type %d\n", len);
      return msg;
    }
    dbg(GENERAL_CHANNEL, "\tPackage(%d,%d) is Corrupted", recievedMsg->src, recievedMsg->dest);
    return msg;
}

  event void CommandHandler.ping(uint16_t destination, uint8_t *payload){
    sequenceCounter++;
    makePack(&sendPackage, TOS_NODE_ID, destination, MAX_TTL + 5, PROTOCOL_PING, sequenceCounter, payload, PACKET_MAX_PAYLOAD_SIZE);
    packLog(&sendPackage);
    call Sender.send(sendPackage, AM_BROADCAST_ADDR);
  }
/*
    else if(myMsg->dest == AM_BROADCAST_ADDR) { //check if looking for neighbors

				bool found;
				bool match;
				uint16_t length;
				uint16_t i = 0;
				Neighbor neighbor1,  neighbor2, neighborCheck;
				//if the packet is sent to ping for neighbors
				if (myMsg->protocol == PROTOCOL_PING){
					//send a packet that expects replies for neighbors
					//dbg(NEIGHBOR_CHANNEL, "Packet sent from %d to check for neighbors\n", myMsg->src);
					makePack(&sendPackage, TOS_NODE_ID, AM_BROADCAST_ADDR, myMsg->TTL-1, PROTOCOL_PINGREPLY, myMsg->seq, (uint8_t *) myMsg->payload, PACKET_MAX_PAYLOAD_SIZE);
					pushPack(sendPackage);
					call Sender.send(sendPackage, myMsg->src);

		      }

          //if the packet is sent to ping for replies
				else if (myMsg->protocol == PROTOCOL_PINGREPLY){
					//update ping number, search and see if the neighbor was found
					//dbg(NEIGHBOR_CHANNEL, "Packet recieved from %d, replying\n", myMsg->src);
					length = call NeighborsList.size();
					found = FALSE;
					for (i = 0; i < length; i++){
						neighbor2 = call NeighborsList.get(i);
						//dbg(GENERAL_CHANNEL, "Pings at %d = %d\n", neighbor2.Node, neighbor2.pingNumber);
						if (neighbor2.Node == myMsg->src) {
							//dbg(NEIGHBOR_CHANNEL, "Node found, adding %d to list\n", myMsg->src);
							//reset the ping number if found to keep it from being dropped
							neighbor2.pingNumber = 0;
							found = TRUE;
						}
					}
				}
				//if the packet is sent to find other nodes
				else if (myMsg->protocol == PROTOCOL_LINKSTATE) {
					//store the LSP in a list of structs
					LinkState LSP;
					LinkState temp;
					Neighbor Ntemp;
					bool end, from, good;
					uint16_t j,size,k;
					uint16_t count;
					uint16_t* arr;
					bool same;
					bool replace;
					count = 0;
					end = TRUE;
					from = FALSE;
					good = TRUE;
					found = FALSE;
					i = 0;
					if (myMsg->src != TOS_NODE_ID){
						arr = myMsg->payload;
						size = call RoutingTable.size();
						LSP.Dest = myMsg->src;
						LSP.Seq = myMsg->seq;
						LSP.Cost = MAX_TTL - myMsg->TTL;
						//dbg(GENERAL_CHANNEL, "myMsg->TTL is %d, LSP.Cost is %d, good is %d\n", myMsg->TTL, LSP.Cost, good);

						if (!call RoutingTable.isEmpty()){
							dbg(GENERAL_CHANNEL, "list before removal loop\n");
							printLSP();
							for (i = 0; i < call RoutingTable.size(); i++){
								dbg(GENERAL_CHANNEL, "RoutingTable.size() is %d\n", call RoutingTable.size());
								temp = call RoutingTable.get(i);
								if ((temp.Dest == LSP.Dest) && (LSP.Seq >= temp.Seq))
								{
									dbg(ROUTING_CHANNEL, "Deleting %d and replaced %d, i is %d\n",temp.Dest, LSP.Dest, i);
									if((i+1) == size)
									{
										dbg(GENERAL_CHANNEL, "removing using popback()\n");
										call RoutingTable.popback();
									}
									else
									{
										dbg(GENERAL_CHANNEL, "removing using removeFromList()\n");
										k = i;
										call RoutingTable.removeFromList(k);
									}
								}
							}
							i=0;
							while(!call RoutingTable.isEmpty())
							{
								temp = call RoutingTable.front();
								if((temp.Dest == LSP.Dest) && (LSP.Seq >= temp.Seq))
								{
									call RoutingTable.popfront();
								}
								else
								{
									call TentativeTable.pushfront(call RoutingTable.front());
									call RoutingTable.popfront();
								}
							}
							while(!call TentativeTable.isEmpty())
							{
								call RoutingTable.pushback(call TentativeTable.front());
								call TentativeTable.popfront();
							}
							dbg(GENERAL_CHANNEL, "list after removal loop\n");
							printLSP();
						}
						i=0;
						count=0;
						while(arr[i] > 0)
						{
							LSP.Neighbors[i] = arr[i];
							//dbg(GENERAL_CHANNEL, "arr[i] = %d\n", arr[i]);
							count++;
							i++;
						}
						LSP.Next = 0;
						LSP.NeighborsLength = count;
						dbg(ROUTING_CHANNEL, "Table for %d: \n", TOS_NODE_ID);
						//if(good == TRUE)
						//{
							call RoutingTable.pushfront(LSP);
						//}
						findNext();
						printLSP();
						sequenceCounter++;
						makePack(&sendPackage, myMsg->src, AM_BROADCAST_ADDR, myMsg->TTL-1, PROTOCOL_LINKSTATE, sequenceCounter, (uint8_t *)myMsg->payload, (uint8_t) sizeof(myMsg->payload));
						pushPack(sendPackage);
						call Sender.send(sendPackage, AM_BROADCAST_ADDR);
					}
				}
				//if we didn't find a match
				if (!found && myMsg->protocol != PROTOCOL_LINKSTATE)
				{
					//add it to the list, using the memory of a previous dropped node
					neighbor1 = call NeighborsDropped.get(0);
					//check to see if already in list
					length = call NeighborsList.size();
					for (i = 0; i < length; i++)
					{
						neighborCheck = call NeighborsList.get(i);
						if (myMsg->src == neighborCheck.Node)
						{
							match = TRUE;
						}
					}
					if (match == TRUE)
					{
						//already in the list, no need to repeat
					}
					else
					{
						//not in list, so we're going to add it
            LinkState temp;
						//dbg(NEIGHBOR_CHANNEL, "%d not found, put in list\n", myMsg->src);
						neighbor1.Node = myMsg->src;
						neighbor1.pingNumber = 0;
						call NeighborsList.pushback(neighbor1);

					}
				}

    } else if(myMsg->protocol == 0 && (myMsg->dest == TOS_NODE_ID)) {      //Check if correct protocol is run. Check the destination node ID

        dbg(FLOODING_CHANNEL, "Packet destination achieved. Package Payload: %s\n", myMsg->payload);    //Return message for correct destination found and its payload.
        makePack(&sendPackage, TOS_NODE_ID, myMsg->src, MAX_TTL, PROTOCOL_PINGREPLY, sequenceCounter, (uint8_t *) myMsg->payload, sizeof(myMsg->payload));      //Make new pack
        sequenceCounter++;      //Increment our sequence number
        pushPack(sendPackage);  //Push the pack again
        call Sender.send(sendPackage, AM_BROADCAST_ADDR);       //Rebroadcast

    } else if((myMsg->dest == TOS_NODE_ID) && myMsg->protocol == 1) {   //Check if correct protocol is run. Check the destination node ID

        dbg(FLOODING_CHANNEL, "Recieved a reply it was delivered from %d!\n", myMsg->src);   //Return message for pingreply and get the source of where it came from

    } else {

        makePack(&sendPackage, myMsg->src, myMsg->dest, myMsg->TTL-1, myMsg->protocol, myMsg->seq, (uint8_t *)myMsg->payload, sizeof(myMsg->payload));      //make new pack
        dbg(FLOODING_CHANNEL, "Recieved packet from %d, meant for %d, TTL is %d. Rebroadcasting\n", myMsg->src, myMsg->dest, myMsg->TTL);        //Give data of source, intended destination, and TTL
        pushPack(sendPackage);          //Push the pack again
        call Sender.send(sendPackage, AM_BROADCAST_ADDR);       //Rebroadcast

        }
    return msg;
}
    dbg(GENERAL_CHANNEL, "Unknown Packet Type %d\n", len);
    return msg;
}


    event void CommandHandler.ping(uint16_t destination, uint8_t *payload){
    dbg(GENERAL_CHANNEL, "PING EVENT \n");
    makePack(&sendPackage, TOS_NODE_ID, destination, MAX_TTL, 0, 0, payload, PACKET_MAX_PAYLOAD_SIZE);
    call Sender.send(sendPackage, AM_BROADCAST_ADDR);
    }
*/

    //Printing functions
    event void CommandHandler.printNeighbors(){

      int i, cnt = 0;
      dbg(GENERAL_CHANNEL, "Neighbors Size: %d\n", NeighborsListSize);
      for(i = 1; i < (NeighborsListSize); i++) {
           if(Neighbors[i] > 0){
                dbg(NEIGHBOR_CHANNEL, "%d -> %d\n", TOS_NODE_ID, i);
                cnt++;
           }
      }
      if(cnt == 0)
            dbg(GENERAL_CHANNEL, "Neighbor List is Empty\n");

   }

    event void CommandHandler.printRouteTable(){

      int i;
      dbg(GENERAL_CHANNEL, "\t%d's Routing Table\n", TOS_NODE_ID);
      dbg(GENERAL_CHANNEL, "\tDest\tCost\tCount\n");
      for (i = 1; i < 20; i++) {
              dbg(GENERAL_CHANNEL, "\t  %d \t  %d \t    %d \n", Routing[i][0], Routing[i][1], Routing[i][2]);
      }

    }

    event void CommandHandler.printLinkState(){}

    event void CommandHandler.printDistanceVector(){}

    event void CommandHandler.setTestServer(){}

    event void CommandHandler.setTestClient(){}

    event void CommandHandler.setAppServer(){}

    event void CommandHandler.setAppClient(){}

//Pack handler functions
    void makePack(pack *Package, uint16_t src, uint16_t dest, uint16_t TTL, uint16_t protocol, uint16_t seq, uint8_t* payload, uint8_t length){
            Package->src = src;
            Package->dest = dest;
            Package->TTL = TTL;
            Package->seq = seq;
            Package->protocol = protocol;
            memcpy(Package->payload, payload, length);
    }

    void packLog(pack *payload) {
      pack loggedP;
      uint16_t src = payload->src;
      uint16_t seq = payload->seq;
      //Test if list contains the src key & check if its empty
      if (call PackList.size() == 64) {
        call PackList.popfront();
      }
      makePack(&loggedP, payload->src, payload->dest, payload->TTL, payload->protocol, payload->seq, (uint8_t*) payload->payload, sizeof(pack));
      call PackList.pushback(loggedP);

    }

    bool packSeen(pack *packet) {
      pack store;
      int x, size;
      size = call PackList.size();

      if(size > 0) {
        for (x = 0; x < size; x++) {
          store = call PackList.get(x);
          if (store.src == packet->src && store.seq == packet->seq) {
            return 1;
          }
        }
      }
      return 0;
    }

  /*  bool findPack(pack *Package) {      //findpack function
        uint16_t size = call PackList.size();     //get size of the list
        pack Match;                 //create variable to test for matches
        uint16_t i = 0;             //initialize variable to 0
        for (i = 0; i < size; i++) {
            Match = call PackList.get(i);     //iterate through the list to test for matches
            if((Match.src == Package->src) && (Match.dest == Package->dest) && (Match.seq == Package->seq)) {   //Check for matches of source, destination, and sequence number
                return TRUE;
                }
            }
            return FALSE;
        }

    void pushPack(pack Package) {   //pushpack function
        if (call PackList.isFull()) {
            call PackList.popfront();         //if the list is full, pop off the front
        }
        call PackList.pushback(Package);      //continue adding packages to the list
    }
*/

//Neighbor Discovery

    void addNeighbor(uint8_t Neighbor) {
      if(Neighbor == 0)
          dbg(GENERAL_CHANNEL, "This is the neighbor at Source 0");
       Neighbors[Neighbor] = maxNeighborTTL;
    }

    void lessNeighborTTL() {
      int i;
      for (i = 0; i < NeighborsListSize; i++) {
            if(Neighbors[i] == 1) {
                  Neighbors[i] -= 1;
                  Routing[i][1] = 255;
                  dbg (NEIGHBOR_CHANNEL, "\t Node %d Dropped from the Network \n", i);

                  // NeighborPing to neighbor we are dropppping
                  sequenceCounter++;
                  makePack(&sendPackage, TOS_NODE_ID, AM_BROADCAST_ADDR, 1, PROTOCOL_PING, sequenceCounter, "Searching for Neighbors", PACKET_MAX_PAYLOAD_SIZE);
                  call Sender.send(sendPackage, (uint8_t) i);
            }
            if (Neighbors[i] > 1) {
                  Neighbors[i] -= 1;
            }
      }
    }

    void sendToNeighbor(pack *recievedMsg) {
      if(destIsNeighbor(recievedMsg)) {
              dbg(NEIGHBOR_CHANNEL, "\tDeliver to Destination\n");
              call Sender.send(sendPackage, recievedMsg->dest);
        } else {
                //dbg(NEIGHBOR_CHANNEL, "\tTrynna Forward To Neighbors\n");
              call Sender.send(sendPackage, AM_BROADCAST_ADDR);
        }
    }

    void destNeighbor(pack *recievedMsg){
      if(Neighbors[recievedMsg->dest] > 0)
          return 1;
      return 0;
    }

    void scanForNeighbors(){
      int i;
      if (!initialized) {
             sequenceCounter++;
             makePack(&sendPackage, TOS_NODE_ID, AM_BROADCAST_ADDR, 1, PROTOCOL_PING, sequenceCounter, "Searching for Neighbors", PACKET_MAX_PAYLOAD_SIZE);
             call Sender.send(sendPackage, AM_BROADCAST_ADDR);
      } else  {
             reduceNeighborsTTL();
      }
    }

    /*
    void discoverNeighbors(){

      pack Pack; //Packet to be sent to neighbors
      char* message; //increase the access counter
      accessCounter++;
      dbg(NEIGHBOR_CHANNEL, "Neighbors accessed, %d is checking.\n", TOS_NODE_ID); //check to see if neighbors have been found at all
      if (!(call NeighborsList.isEmpty())) {
        uint16_t length = call NeighborsList.size();
        uint16_t pings = 0;
        Neighbor NeighborNode;
        uint16_t i = 0;
        Neighbor temp; //increase the number of pings in the neighbors in the list
        for (i = 0; i < length; i++){
          temp = call NeighborsList.get(i);
          temp.pingNumber = temp.pingNumber + 1;
          pings = temp.pingNumber;
          dbg(ROUTING_CHANNEL, "Pings at %d: %d\n", temp.Node, pings);
          if (pings > 3){ //drop neighbor if greater than 3 pings
            NeighborNode = call NeighborsList.removeFromList(i);
            dbg(NEIGHBOR_CHANNEL, "Node %d dropped due to more than 3 pings\n", NeighborNode.Node);
            call NeighborsDropped.pushfront(NeighborNode);
            i--;
            length--;
          }
        }
      }
      //ping the list of Neighbors
      message = "Pinged Neighbors List\n";
      makePack(&Pack, TOS_NODE_ID, AM_BROADCAST_ADDR, 2, PROTOCOL_PING, 1, (uint8_t*) message, (uint8_t) sizeof(message));
      pushPack(Pack); //add the packet to the packet list
      call Sender.send(Pack, AM_BROADCAST_ADDR);

    } */

    void initializeRT() {
        int i, j, neighbor;
        bool contains;
        dbg(ROUTING_CHANNEL, "\tMOTE(%d) Initializing Routing Table\n");

        // Setting all the Nodes in our pool/Routing table to  MAX_HOP and setting their nextHop to our emlpty first cell
        for(i = 1; i < 20; i++) {
                Routing[i][0] = i;
                Routing[i][1] = 255;
                Routing[i][2] = 0;
        }

        // Setting the cost for SELF
        Routing[TOS_NODE_ID][0] = TOS_NODE_ID;
        Routing[TOS_NODE_ID][1] = 0;
        Routing[TOS_NODE_ID][2] = TOS_NODE_ID;

        // Setting the cost to all my neighbors
        for(j = 1; j < NeighborsListSize; j++) {
                 if(Neighbors[j] > 0)
                      insert(j, 1, j);
        }
        /* dbg(GENERAL_CHANNEL, "\t~~~~~~~My, Mote %d's, Neighbors~~~~~~~initialize\n", TOS_NODE_ID);
        signal CommandHandler.printNeighbors(); */
   }

   void insertRT(uint8_t dest, uint8_t cost, uint8_t nextHop) {
        //input data into tuple
        Routing[dest][0] = dest;
        Routing[dest][1] = cost;
        Routing[dest][2] = nextHop;
  }

  void sendRT() {
      int i;
      for (i = 1; i < NeighborsListSize; i++)
      if(Neighbors[i] > 0)
      splitHorizon((uint8_t)i);
  }

  bool mergeRoute(uint8_t *newRoute, uint8_t src) {

    int node, cost, next, i, j;
    bool alteredRoute = false;

    for (i = 0; i < 20; i++) {
        for (j = 0; j < 7; j++) {
            // Saving values for cleaner Code
            node = *(newRoute + (j * 3));
            cost = *(newRoute + (j * 3) + 1);
            next = *(newRoute + (j * 3) + 2);

            if (node == routing[i][0]) {
                    if ((cost+1)<routing[i][1]) {
                            Routing[i][0] = node;
                            Routing[i][1] = cost + 1;
                            Routing[i][2] = src;

                            alteredRoute = TRUE;
                    }
            }
        }
    }

    return alteredRoute;

  }

  void splitHorizon(uint8_t nextHop) {

    int i, j;

    //The below values will keep track of the first node
    uint8_t* start;
    uint8_t* poisonTable = NULL;
    poisonTable = malloc(sizeof(Routing));
    start = malloc(sizeof(Routing));

    //Using memcpy to copy routing table information
    memcpy(poisonTable, &Routing, sizeof(Routing));
    start = poisonTable;

    //Poison Control Implementation: make the path cost the max hop at the moment
    for(i = 0; i < 20; i++)
      if (nextHop == i)
        *(poisonTable + (i*3) + 1) = 25;

    //Semd the payload into seperate parts
    for(i = 0; i < 20; i++) {
      if(i % 7 == 0){
          sequenceCounter++;
          makePack(&sendPackage, TOS_NODE_ID, nextHop, 2, PROTOCOL_DV, sequenceCounter, poisonTabel, sizeof(Routing));
          call Sender.send(sendPackage, nextHop);
      }
        poisonTable += 3;
     }

  }

/*
  void route(uint16_t Dest, uint16_t Cost, uint16_t Next) {
		LinkState Link, temp, temp2, temp3, temp4;
		Neighbor next;
		uint8_t i, j, k, m, n, p, q, r;
		bool inTent, inCon;
		Link.Dest = Dest;
		Link.Cost = Cost;
		Link.Next = Next;
		j = 0;
		call ConfirmedTable.pushfront(Link);

		if (Link.Dest != TOS_NODE_ID) {
			//dbg(ROUTING_CHANNEL, "not TOS_NODE_ID\n");
			for (i = 0; i < call RoutingTable.size(); i++) {
				temp = call RoutingTable.get(i);
				if (temp.Dest == Dest) {
					for (j = 0; j < temp.NeighborsLength; j++) {
						if (temp.Neighbors[j] > 0) {
							inTent = FALSE;
							inCon = FALSE;
							if (!call TentativeTable.isEmpty()) {
								for (k = 0; k < call TentativeTable.size(); k++) {
									temp2 = call TentativeTable.get(k);
									if (temp2.Dest == temp.Neighbors[j]) {
										inTent = TRUE;
									}
								}
							}
							if (!call ConfirmedTable.isEmpty()) {
								for (m = 0; m < call ConfirmedTable.size(); m++) {
									temp3 = call ConfirmedTable.get(m);
									if (temp3.Dest == temp.Neighbors[j]) {
										inCon = TRUE;
									}
								}
							}
							if (!inTent && !inCon) {
								temp.Dest = temp.Neighbors[j];
								temp.Cost = Cost+1;
								temp.Next = Dest;
								call TentativeTable.pushfront(temp);
							}
						}
					}
				}
			}
		}

		else {
			for (j = 0; j < call NeighborsList.size(); j++) {
				next = call NeighborsList.get(j);
				for (n = 0; n < call RoutingTable.size(); n++) {
					temp = call RoutingTable.get(n);
					if (temp.Dest == next.Node) {
						inTent = FALSE;
						inCon = FALSE;
						if (!call TentativeTable.isEmpty()) {
							for (k = 0; k < call TentativeTable.size(); k++) {
								temp2 = call TentativeTable.get(k);
								if (temp2.Dest == temp.Dest && temp2.Cost > temp.Cost) {
									temp4 = call TentativeTable.removeFromList(k);
									temp4.Cost = temp.Cost;
									temp4.Next = temp.Next;
									call TentativeTable.pushfront(temp4);
									inTent = TRUE;
								}
								if (temp2.Dest == temp.Dest && temp2.Cost == temp.Cost) {
									inTent = TRUE;
								}
							}
						}
						if (!call ConfirmedTable.isEmpty()) {
							//dbg(ROUTING_CHANNEL, "debugConfirmedTableNotEmpty\n");
							for (m = 0; m < call ConfirmedTable.size(); m++) {
								temp3 = call ConfirmedTable.get(m);
								if (temp3.Dest == temp.Dest) {
									//dbg(ROUTING_CHANNEL, "ConSetTrue\n");
									inCon = TRUE;
								}
							}
						}
						if (!inTent && !inCon) {
							//dbg(ROUTING_CHANNEL, "noTent and noCon\n");
							call TentativeTable.pushfront(temp);
						}
					}
				}
			}
		}

		inCon = FALSE;
		p = call TentativeTable.size();
		//dbg(ROUTING_CHANNEL, "p = %d\n", p);
		if (p == 1) {
			temp4 = call TentativeTable.get(0);
			call TentativeTable.popback();
			inCon = FALSE;
			for (m = 0; m < call ConfirmedTable.size(); m++) {
				temp3 = call ConfirmedTable.get(m);
				if (temp4.Dest == temp3.Dest) {
					inCon = TRUE;
				}
				if (!inCon) {
					if (temp4.Next == temp3.Dest) {
						temp4.Next = temp3.Next;
						for (j = 0; j < call NeighborsList.size(); j++) {
							next = call NeighborsList.get(j);
							if (temp4.Next == next.Node) {
								break;
							}
						}
					}
				}
			}
			if (!inCon) {
				route(temp4.Dest, temp4.Cost, temp4.Next);
			}
		}

		if (p > 1) {
			//inCon = FALSE;
			temp4 = call TentativeTable.get(0);
			q = 0;
			for (k = 1; k < call TentativeTable.size(); k++) {
				temp2 = call TentativeTable.get(k);
				if (temp4.Cost > temp2.Cost) {
					q = k;
					temp4 = temp2;
				}
				else if (temp4.Cost == temp2.Cost && temp4.Dest > temp2.Dest) {
					q = k;
					temp4 = temp2;
				}
			}
			temp2 = call TentativeTable.get(q);
			for (m = 0; m < call ConfirmedTable.size(); m++) {
				temp3 = call ConfirmedTable.get(q);
				if (temp2.Dest == temp3.Dest) {
					inCon = TRUE;
				}
				if (!inCon) {
					if (temp4.Next == temp3.Dest) {
						temp4.Next = temp3.Next;
						for (j = 0; j < call NeighborsList.size(); j++) {
							next = call NeighborsList.get(j);
							if (temp4.Next == next.Node) {
								break;
							}
						}
					}
				}
			}
			if (!inCon) {
				if (call TentativeTable.size() - 1 > 1 && q == call TentativeTable.size() -1) {
					call TentativeTable.popback();
				}
				else {
					call TentativeTable.removeFromList(q);
					call TentativeTable.popback();
				}
				route(temp4.Dest, temp4.Cost, temp4.Next);
			}
		}
	} */
}
