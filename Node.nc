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

module Node{

    uses interface Boot;
    uses interface SplitControl as AMControl;
    uses interface Receive;
    uses interface SimpleSend as Sender;
    uses interface CommandHandler;
    uses interface List<pack> as PackList;     //Create list of pack called PackList
    uses interface List<uint16_t> as NeighborsList; //Create list of neighbors
    uses interface Timer<TMilli> as periodTimer; //Creates implementation of timer for neighbor periods
}

implementation{
    uint16_t sequenceCounter = 0;             //Create a counter

    pack sendPackage;
    // Prototypes

    void discoverNeighbors();
    void makePack(pack *Package, uint16_t src, uint16_t dest, uint16_t TTL, uint16_t Protocol, uint16_t seq, uint8_t *payload, uint8_t length);

    bool findPack(pack *Package);           //Function to find packs (Implementation at the end)
    void pushPack(pack Package);            //Function to push packs (Implementation at the end)

    event void periodTimer.fired(){
       //ping(TOS_NODE_ID, "NEIGHBOR SEARCH");
       discoverNeighbors();
       //dbg(NEIGHBOR_CHANNEL,"Neighboring nodes %s\n", Neighbor);
       CommandHandler.printNeighbors;
       //dbg(NEIGHBOR_CHANNEL,"Neighboring nodes %s\n", Neighbor);

   }

    event void Boot.booted(){
    call AMControl.start();
    call periodTimer.startPeriodic(5000);

    dbg(GENERAL_CHANNEL, "Booted\n");
}

event void AMControl.startDone(error_t err){
    if(err == SUCCESS){
        dbg(GENERAL_CHANNEL, "Radio On\n");
    }else{
        //Retry until successful
        call AMControl.start();
        }
    }

event void AMControl.stopDone(error_t err){}

event message_t* Receive.receive(message_t* msg, void* payload, uint8_t len){
    dbg(GENERAL_CHANNEL, "Packet Received\n");
    if(len==sizeof(pack)){
        pack* myMsg=(pack*) payload;

    if((myMsg->TTL == 0) || findPack(myMsg)){

    //If no more TTL or pack is already in the list, we will drop the pack

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

    event void CommandHandler.printNeighbors(){}

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
            //uint16_t tTol = 1;
            makePack(&sendPackage, TOS_NODE_ID, TOS_NODE_ID, 1, PROTOCOL_PING, sequence++, "HI NEIGHBOR", PACKET_MAX_PAYLOAD_SIZE);
            call Sender.send(sendPackage, AM_BROADCAST_ADDR);
            CommandHandler.printNeighbors;
    }

    event void CommandHandler.printNeighbors(){

       uint16_t i = 0;
       uint16_t max = call NeighborsList.size();

       for(i = 0; i < max;i++){
           dbg(NEIGHBOR_CHANNEL,"Printing\n");
           uint16_t Neighbor = call NeighborsList.get(i);
           printf('%s', Neighbor);
           dbg(NEIGHBOR_CHANNEL,"Neighboring nodes %s\n", Neighbor);

       }
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
}
