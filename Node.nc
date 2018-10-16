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

typedef nx_struct Neighbor {
   nx_uint16_t Node;
   nx_uint16_t pingNumber;
}Neighbor;

typedef nx_struct LinkState {
   nx_uint16_t Dest;
   nx_uint16_t Cost;
   nx_uint16_t Next;
   nx_uint16_t Seq;
   nx_uint8_t Neighbors[64];
   nx_uint16_t NeighborsLength;
}LinkState;

module Node{

    uses interface Boot;
    uses interface SplitControl as AMControl;
    uses interface Receive;
    uses interface SimpleSend as Sender;
    uses interface CommandHandler;

    uses interface List<pack> as PackList;     //Create list of pack called PackList

    uses interface List<Neighbor> as NeighborsList; //Create list of neighbors
    uses interface List<Neighbor> as NeighborsDropped; //Creates list of dropped neighbors
    uses interface List<Neighbor> as NeighborCosts; //Creates list of neighboring nodes costs

    uses interface List<LinkState> as RoutingTable; //Link State table used for routing route
    uses interface List<LinkState> as ConfirmedTable; //ConfirmedTable table
    uses interface List<LinkState> as TentativeTable; //TentativeTable Table

    uses interface Timer<TMilli> as periodTimer; //Creates implementation of timer for neighbor periods

}

implementation{

    uint16_t sequenceCounter = 0;             //Create a sequence counter
    uint16_t accessCounter = 0;               //Create an access counter

    pack sendPackage;

    void discoverNeighbors();
    void makePack(pack *Package, uint16_t src, uint16_t dest, uint16_t TTL, uint16_t Protocol, uint16_t seq, uint8_t *payload, uint8_t length);

    bool findPack(pack *Package);           //Function to find packs (Implementation at the end)
    void pushPack(pack Package);            //Function to push packs (Implementation at the end)

    //void route(uint16_t Dest, uint16_t Cost, uint16_t Next);
    void route();
    void findNext();

    void floodLSP();
    void printLSP();

    event void periodTimer.fired(){
       discoverNeighbors();
       //dbg(NEIGHBOR_CHANNEL,"Neighboring nodes %s\n", Neighbor);
       CommandHandler.printNeighbors;
       //dbg(NEIGHBOR_CHANNEL,"Neighboring nodes %s\n", Neighbor);
       if (accessCounter > 1 && accessCounter % 5 == 0 && accessCounter < 16){
		       floodLSP();
		       printLSP();
		       findNext();
	}
      if (accessCounter > 1 && accessCounter % 20 == 0 && accessCounter < 61)
        route();

   }

    event void Boot.booted(){
    call AMControl.start();
    call periodTimer.startPeriodic(5000);

    dbg(GENERAL_CHANNEL, "Booted\n");
  }

    event void AMControl.startDone(error_t err){
      if(err == SUCCESS){
          dbg(GENERAL_CHANNEL, "Radio On\n");
      }
      else{
          call AMControl.start(); //Retry until success
          }
      }

      event void AMControl.stopDone(error_t err){}

    event message_t* Receive.receive(message_t* msg, void* payload, uint8_t len){
    dbg(GENERAL_CHANNEL, "Packet Received\n");
    if(len==sizeof(pack)){
        pack* myMsg=(pack*) payload;

    if((myMsg->TTL == 0) || findPack(myMsg)){

    //If no more TTL or pack is already in the list, we will drop the pack

    }

    else if(myMsg->dest == AM_BROADCAST_ADDR) { //check if looking for neighbors

				bool found;
				bool match;
				uint16_t length;
				uint16_t i = 0;
				Neighbor neighbor1,  neighbor2, neighborCheck;
				//if the packet is sent to ping for neighbors
				if (myMsg->protocol == PROTOCOL_PING){
					//send a packet that expects replies for neighbors
					dbg(NEIGHBOR_CHANNEL, "Packet sent from %d to check for neighbors\n", myMsg->src);
					makePack(&sendPackage, TOS_NODE_ID, AM_BROADCAST_ADDR, myMsg->TTL-1, PROTOCOL_PINGREPLY, myMsg->seq, (uint8_t *) myMsg->payload, PACKET_MAX_PAYLOAD_SIZE);
					pushPack(sendPackage);
					call Sender.send(sendPackage, myMsg->src);

		      }

          //if the packet is sent to ping for replies
				else if (myMsg->protocol == PROTOCOL_PINGREPLY){
					//update ping number, search and see if the neighbor was found
					dbg(NEIGHBOR_CHANNEL, "Packet recieved from %d, replying\n", myMsg->src);
					length = call NeighborsList.size();
					found = FALSE;
					for (i = 0; i < length; i++){
						neighbor2 = call NeighborsList.get(i);
						dbg(GENERAL_CHANNEL, "Pings at %d = %d\n", neighbor2.Node, neighbor2.pingNumber);
						if (neighbor2.Node == myMsg->src) {
							dbg(NEIGHBOR_CHANNEL, "Node found, adding %d to list\n", myMsg->src);
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
						dbg(NEIGHBOR_CHANNEL, "%d not found, put in list\n", myMsg->src);
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

    event void CommandHandler.printNeighbors(){

      uint16_t i = 0;
      uint16_t length = call NeighborsList.size();
      Neighbor beingPrinted;
      if (length == 0){
        dbg(NEIGHBOR_CHANNEL, "No neighbors exist\n");
      }
      else {
        for (i = 0; i < length; i++){
          beingPrinted = call NeighborsList.get(i);
          dbg(NEIGHBOR_CHANNEL, "Neighbor found at %d\n", beingPrinted.Node, i);
          }
}

   }

    event void CommandHandler.printRouteTable(){}

    event void CommandHandler.printLinkState(){}

    event void CommandHandler.printDistanceVector(){}

    event void CommandHandler.setTestServer(){}

    event void CommandHandler.setTestClient(){}

    event void CommandHandler.setAppServer(){}

    event void CommandHandler.setAppClient(){}

    void makePack(pack *Package, uint16_t src, uint16_t dest, uint16_t TTL, uint16_t protocol, uint16_t seq, uint8_t* payload, uint8_t length){
            Package->src = src;
            Package->dest = dest;
            Package->TTL = TTL;
            Package->seq = seq;
            Package->protocol = protocol;
            memcpy(Package->payload, payload, length);
        }

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

    }

    bool findPack(pack *Package) {      //findpack function
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

    void printLSP()
    {
       LinkState temp;
       uint16_t i, j;
       for(i=0; i < call RoutingTable.size(); i++)
     {
       temp = call RoutingTable.get(i);
       dbg(GENERAL_CHANNEL, "LSP from %d, Cost: %d, Next: %d, Seq: %d, Count; %d\n", temp.Dest, temp.Cost, temp.Next, temp.Seq, temp.NeighborsLength);
       for(j=0; j<temp.NeighborsLength; j++)
       {
         dbg(GENERAL_CHANNEL, "Neighbor at %d\n", temp.Neighbors[j]);
       }
     }
     dbg(GENERAL_CHANNEL, "size is %d\n", call RoutingTable.size());
   }

   void floodLSP(){ //Run to flood LSPs, sending info of this node's direct neighbors
		pack LSP;
		LinkState O;
		dbg(ROUTING_CHANNEL, "LSP Initial Flood from %d\n", TOS_NODE_ID);
		if (!call NeighborsList.isEmpty()){ //Check to see if there are any neighbors
			uint16_t i = 0;
			uint16_t length = call NeighborsList.size();
			uint16_t directNeighbors[length+1];
			Neighbor temp;
		dbg(ROUTING_CHANNEL, "length = %d/n", length);
			for (i = 0; i < length; i++) { //Push neighbors into the array
				temp = call NeighborsList.get(i);
				directNeighbors[i] = temp.Node;
			}
			directNeighbors[length] = 0;
			directNeighbors[length+1] = TOS_NODE_ID;
			dbg(ROUTING_CHANNEL, "this should be 0: %d\n", directNeighbors[length]);
			//Flood the packet
			makePack(&LSP, TOS_NODE_ID, AM_BROADCAST_ADDR, MAX_TTL-1, PROTOCOL_LINKSTATE, sequenceCounter++, (uint16_t*)directNeighbors, (uint16_t) sizeof(directNeighbors));
			pushPack(LSP);
			call Sender.send(LSP, AM_BROADCAST_ADDR);
		}
	}

  void findNext()
	{
		uint16_t i,j,k,CC;
		uint16_t tablesize,tentsize;
		LinkState LSP, LSP2;
		bool popped = FALSE;
		tablesize = call RoutingTable.size();
		tentsize = call TentativeTable.size();
		//Adds LSPs on routing table to TentativeTable based on cost
		i=0;
		while (tentsize != tablesize)
		{
			LSP = call RoutingTable.get(i);

		}
		//Check the TentativeTables
		i=0;
		while(!call TentativeTable.isEmpty())
		{
			k=0;
			LSP = call TentativeTable.get(i);
			LSP2 = call TentativeTable.get(k);
			CC = LSP.Cost;
			popped = FALSE;
			//Check to see if neighbors is TOS_NODE_ID
			for(j = 0; j < LSP.NeighborsLength; j++)
			{
				if(LSP.Neighbors[j] == TOS_NODE_ID)
				{
					LSP.Next = LSP.Dest;
					call ConfirmedTable.pushfront(LSP);
					call TentativeTable.popfront();
					popped = TRUE;
					break;
				}
			}
			if(popped = FALSE)
			{
				for(j=0; j<LSP.NeighborsLength; j++)
				{
					while(LSP2.Dest != LSP.Neighbors[j] && k < tablesize)
					{
						k++;
						LSP2 = call TentativeTable.get(k);
					}

				}
			}
		}
	}

  void route()
	{
		int nodesize[20];
		int size = call RoutingTable.size();
		int mn = 20;
		int i,j,nexthop,cost[mn][mn],distance[mn],plist[mn];
		int visited[mn],ncount,mindistance,nextnode;

		int start_node = TOS_NODE_ID;
		bool aMatrix[mn][mn];

		LinkState temp, temp2;

		for(i = 0; i < mn; i++)
		{
			for(j = 0; j < mn; j++)
			{
				aMatrix[i][j] = FALSE;
			}
		}

		for(i = 0; i < size; i++)
		{
			temp = call RoutingTable.get(i);
			for(j = 0; j < temp.NeighborsLength; j++)
			{
				aMatrix[temp.Dest][temp.Neighbors[j]] = TRUE;
			}
		}

		for(i = 0; i < mn; i++)
		{
			for(j = 0; j < mn; j++)
			{
				if(aMatrix[i][j] == FALSE)
				{
					cost[i][j] = INFINITY;
				}
				else
				{
					cost[i][j] = 1;
				}
			}
		}
		if(TOS_NODE_ID == 1){
		for(i = 0; i < mn; i++)
		{
			for(j = 0; j < mn; j++)
			{
				//printf("i=%d, j=%d, cost=%d\n", i, j, cost[i][j]);
			}
		}
		}

		for(i = 0; i < mn; i++)
		{
			distance[i] = cost[start_node][i];
			plist[i] = start_node;
			visited[i] = 0;
		}

		distance[start_node] = 0;
		visited[start_node] = 1;
		ncount = 1;

		while(ncount < mn - 1)
		{
			mindistance = INFINITY;
			for(i = 0; i < mn; i++)
			{
				if(distance[i] <= mindistance && visited[i] == 0)
				{
					mindistance = distance[i];
					nextnode = i;
				}
			}
			visited[nextnode] = 1;
			for(i = 0; i < mn; i++)
			{
				if(visited[i] == 0)
				{
					if(mindistance + cost[nextnode][i] < distance[i])
					{
						distance[i] = mindistance + cost[nextnode][i];
						plist[i] = nextnode;
					}
				}
			}
			ncount++;
		}

		for(i = 0; i < mn; i++)
		{
			nexthop = TOS_NODE_ID;
			if(distance[i] != INFINITY)
			{
				if(i != start_node)
				{
					j = i;
					do {
						if(j != start_node)
						{
							nexthop = j;
						}
						j = plist[j];
					} while(j != start_node);
				}
				else
				{
					nexthop = start_node;
				}
				if(nexthop != 0)
				{
					call nextTable.insert(i, nexthop);
				}
			}
		}
		if(call Confirmed.isEmpty())
		{
			for(i = 1; i <= 20; i++)
			{
				temp2.Dest = i;
				temp2.Cost = cost[TOS_NODE_ID][i];
				temp2.Next = call nextTable.get(i);
				call Confirmed.pushfront(temp2);
				//dbg(GENERAL_CHANNEL, "confirmed size: %d\n", call Confirmed.size());
			}
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
